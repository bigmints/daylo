import { invoke, isTauri } from '@tauri-apps/api/core'

/**
 * Open an address in whatever the person uses for the web.
 *
 * In a browser this is what a link already does, so there is nothing to do and the anchor
 * is left alone. Inside the application an anchor would navigate the webview itself, which
 * replaces Daylo with a web page and leaves no way back: there is no address bar and no
 * back button on a desktop window. So there the click is taken and handed to the system.
 *
 * Whether to call this at all is decided by the caller, synchronously, because a default
 * can only be prevented before it happens and this cannot answer in time.
 *
 * Says whether it opened, the same way `openMailto` does. Most callers have nothing to do
 * with the answer and ignore it: a web address that will not open is rare and the console
 * is enough. One does not, and it is the reason this stopped returning nothing: a
 * `ms-windows-store://` link is refused by the opener's own scope rather than by the
 * system, which is a failure that looks exactly like a person changing their mind.
 */
export async function openLink(url: string): Promise<'opened' | 'failed'> {
  if (!isTauri()) return 'opened'
  try {
    await invoke('plugin:opener|open_url', { url })
    return 'opened'
  } catch (error) {
    console.error('[Daylo] a link did not open', error)
    return 'failed'
  }
}
