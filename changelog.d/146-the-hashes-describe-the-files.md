**The file of hashes that comes with each release now describes every file in it
correctly.** If you check your downloads with `SHA256SUMS.txt`, one of its lines was wrong:
the one for `latest.json`, the small file Daylo reads to learn a new version is out. It was
written while that file was still being built, so it described the version it replaced.
Everything you actually download was right, and still is. Checking all of it at once no
longer reports a failure for that one line.
