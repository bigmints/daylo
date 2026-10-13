//! Asking the phone things only the phone knows.
//!
//! Everything in here runs on Android and nowhere else, which is why none of it can be
//! run by `cargo test` on a laptop. What can be tested is kept out: the words this module
//! produces are mapped by plain functions in `packaging.rs`, and those are pinned by
//! tests that run anywhere. What is left here is the asking itself.
//!
//! The way in is `ndk_context`, which tao fills in while the activity is created, so by
//! the time any command runs there is a JavaVM and an Activity to borrow. Going through
//! the webview's JNI handle would also work and is what Tauri's own examples show, but it
//! hops to the UI thread and answers through a callback, and nothing here needs either.

use jni::objects::{JObject, JString, JValue};
use jni::JavaVM;

/// Borrow a JNI environment and the app's own Activity for the length of one question.
///
/// Returns None rather than an error for every way this can fail, because every one of
/// them means the same thing to the caller: the phone did not answer. A caller that
/// cannot tell "no" from "could not ask" would have to guess, and this module exists so
/// that the guessing happens in one place with a comment on it.
fn with_the_activity<T>(
    ask: impl FnOnce(&mut jni::JNIEnv, &JObject) -> jni::errors::Result<T>,
) -> Option<T> {
    let context = ndk_context::android_context();
    if context.vm().is_null() || context.context().is_null() {
        return None;
    }

    // SAFETY: both pointers come from ndk_context, which tao filled in with the VM and the
    // Activity it was handed when the app started. Neither is owned here: the JavaVM is
    // borrowed for the length of this function and the Activity is a reference the VM
    // keeps alive for as long as the process has one.
    let vm = unsafe { JavaVM::from_raw(context.vm().cast()) }.ok()?;
    let mut env = vm.attach_current_thread().ok()?;
    // SAFETY: as above. The lifetime is the call below and nothing escapes it.
    let activity = unsafe { JObject::from_raw(context.context().cast()) };

    let answer = ask(&mut env, &activity);

    // A Java exception left pending makes the next JNI call anywhere in the process
    // undefined, and the next JNI call is not ours: it is whatever the webview does on the
    // following frame. So it is cleared here whether or not the question succeeded, and
    // the question is treated as unanswered when one was raised.
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
        return None;
    }
    answer.ok()
}

/// Android's API level, which decides which of the two questions below can be asked.
fn sdk_int(env: &mut jni::JNIEnv) -> jni::errors::Result<i32> {
    let version = env.find_class("android/os/Build$VERSION")?;
    env.get_static_field(version, "SDK_INT", "I")?.i()
}

/// The package that installed this copy, as the phone recorded it, or None.
///
/// None covers three different things and they are all the same answer: nothing installed
/// it through a package of its own (`adb install` leaves no name), the phone refused to
/// say, or the question could not be asked at all.
///
/// `getInstallSourceInfo` arrived in API 30 and `getInstallerPackageName` is what there is
/// below that. The app's minSdk is 24, so both are needed: the older one is deprecated,
/// not gone, and on the phones that have only it, it is the answer.
pub fn installer_package_name() -> Option<String> {
    with_the_activity(|env, activity| {
        let manager = env
            .call_method(
                activity,
                "getPackageManager",
                "()Landroid/content/pm/PackageManager;",
                &[],
            )?
            .l()?;
        let package = env
            .call_method(activity, "getPackageName", "()Ljava/lang/String;", &[])?
            .l()?;

        let installer = if sdk_int(env)? >= 30 {
            let info = env
                .call_method(
                    &manager,
                    "getInstallSourceInfo",
                    "(Ljava/lang/String;)Landroid/content/pm/InstallSourceInfo;",
                    &[JValue::Object(&package)],
                )?
                .l()?;
            env.call_method(
                &info,
                "getInstallingPackageName",
                "()Ljava/lang/String;",
                &[],
            )?
            .l()?
        } else {
            env.call_method(
                &manager,
                "getInstallerPackageName",
                "(Ljava/lang/String;)Ljava/lang/String;",
                &[JValue::Object(&package)],
            )?
            .l()?
        };

        if installer.is_null() {
            return Ok(None);
        }
        Ok(Some(String::from(
            env.get_string(&JString::from(installer))?,
        )))
    })
    .flatten()
}

/// How long to wait for the other end, in milliseconds, for each of connecting and
/// reading. Short on purpose: nothing waits on this answer and nobody asked for it, so a
/// slow network should end in "could not find out" rather than in a request still open
/// when the person has moved on.
const PATIENCE: i32 = 5_000;

/// Fetch a small text document with the phone's own HTTP client.
///
/// Java's and not a Rust one, which keeps a second TLS stack out of the APK and leaves
/// the connection to the platform that is already trusted to make them. No headers are
/// set and no body is sent: what goes out is what any request carries.
///
/// The caller must not be on the interface thread. Android throws
/// NetworkOnMainThreadException there, and a Tauri command is on the main thread unless it
/// is async, so the command that calls this hands it to a blocking thread.
///
/// Every failure is an Err and none of them is an empty string, because "nothing came
/// back" and "nothing is there" are different answers and only one of them is news.
pub fn fetch_text(url: &str, limit: i32) -> Result<String, String> {
    with_the_activity(|env, _activity| {
        let address = env.new_string(url)?;
        let target = env.new_object(
            "java/net/URL",
            "(Ljava/lang/String;)V",
            &[JValue::Object(&address)],
        )?;
        let connection = env
            .call_method(&target, "openConnection", "()Ljava/net/URLConnection;", &[])?
            .l()?;

        env.call_method(
            &connection,
            "setConnectTimeout",
            "(I)V",
            &[JValue::Int(PATIENCE)],
        )?;
        env.call_method(
            &connection,
            "setReadTimeout",
            "(I)V",
            &[JValue::Int(PATIENCE)],
        )?;

        // Resolved against the object's own class, so these reach HttpURLConnection even
        // though openConnection is typed as its parent.
        let status = env
            .call_method(&connection, "getResponseCode", "()I", &[])?
            .i()?;
        if status != 200 {
            return Ok(Err(format!("the address answered {status}")));
        }

        // -1 means the other end did not say, which is allowed; a number that is too big
        // is refused before anything is read rather than after.
        let length = env
            .call_method(&connection, "getContentLength", "()I", &[])?
            .i()?;
        if length > limit {
            return Ok(Err(format!(
                "the answer is {length} bytes, which is too much"
            )));
        }

        let stream = env
            .call_method(
                &connection,
                "getInputStream",
                "()Ljava/io/InputStream;",
                &[],
            )?
            .l()?;
        let encoding = env.new_string("UTF-8")?;
        let scanner = env.new_object(
            "java/util/Scanner",
            "(Ljava/io/InputStream;Ljava/lang/String;)V",
            &[JValue::Object(&stream), JValue::Object(&encoding)],
        )?;
        // The whole stream as one token. \A is "the beginning of input", so there is no
        // second one, which is the shortest way to read a small document through JNI.
        let whole = env.new_string("\\A")?;
        let scanner = env
            .call_method(
                &scanner,
                "useDelimiter",
                "(Ljava/lang/String;)Ljava/util/Scanner;",
                &[JValue::Object(&whole)],
            )?
            .l()?;

        let text = if env.call_method(&scanner, "hasNext", "()Z", &[])?.z()? {
            let token = env
                .call_method(&scanner, "next", "()Ljava/lang/String;", &[])?
                .l()?;
            String::from(env.get_string(&JString::from(token))?)
        } else {
            String::new()
        };

        env.call_method(&connection, "disconnect", "()V", &[])?;
        Ok(Ok(text))
    })
    .unwrap_or_else(|| Err("the phone could not be asked".into()))
}
