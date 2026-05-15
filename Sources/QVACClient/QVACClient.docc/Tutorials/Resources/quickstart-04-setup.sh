# Stage BareKit.xcframework (one-time, ~20MB).
$ cd .build/checkouts/qvac-sdk-swift
$ ./scripts/download-barekit.sh

# Install the test worker fixture so we have a worker entry.
$ cd Tests/Fixtures/qvac-worker
$ npm install
$ ls node_modules/.bin/bare    # the Bare runtime binary
$ ls worker.mjs                # the worker entry
