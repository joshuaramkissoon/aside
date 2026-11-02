// Answers for "Try it here". Each is the model's raw reply in the app's format, made with the app's
// own prompt (bench/run.py, cases try-*; Glasswing through the app's web-search flow) and saved as is.
// try.js parses them the way the app does.
window.ASIDE_ANSWERS = {
 "wal": {
  "raw": "TERM: write-ahead log\nEXPANDS: \nKIND: durability technique\nGIST: Append-only record of changes written and ==flushed to disk before the change is applied==, so a crash can be replayed.\n- `fsync` after the append is what makes it durable; a plain write only reaches the **kernel** page cache.\n- On recovery, replay the log to rebuild state; the log is the source of truth until the main store catches up.\nNEXT:\n? How does WAL differ from a journal?\n? What is group commit?",
  "follow": [
   {
    "q": "How does WAL differ from a journal?",
    "raw": "GIST: Often the same thing — a journal *is* a write-ahead log in most databases; the word just names the ==on-disk file== rather than the ordering rule.\n\n- \"WAL\" stresses the *rule*: log the change before applying it. \"Journal\" stresses the *artifact*: the file you replay.\n- SQLite's rollback journal is the exception — it stores the **old** pages to undo, not the new ones to redo, so it isn't strictly write-ahead.\n- Filesystems (ext4, XFS) say \"journal\"; storage engines (Postgres, RocksDB) say \"WAL\". Same idea, different vocabulary.\nNEXT:\n? What is a redo vs undo log?\n? Why does SQLite use a rollback journal?"
   },
   {
    "q": "What is group commit?",
    "raw": "GIST: Batching several transactions' log records into ==one fsync== so many commits share a single disk flush.\n\n- Trades a little latency per commit for far higher throughput; each client waits for the batch, not its own write.\n- Common in Postgres (`commit_delay`, `commit_siblings`) and in LSM stores that queue appends before flushing.\n- The batch is only durable once that one `fsync` returns — until then, none of the grouped commits are safe.\n\n```\nappend(tx1); append(tx2); append(tx3)\nfsync()          # one flush covers all three\nack(tx1); ack(tx2); ack(tx3)\n```\n\nNEXT:\n? How does commit_delay tune batching?\n? Does group commit break durability guarantees?"
   }
  ]
 },
 "fsync": {
  "raw": "TERM: fsync\nEXPANDS: \nKIND: system call\nGIST: Forces a file's data to ==physical disk==, so it survives a power cut.\n- A plain `flush` only hands bytes to the kernel's page cache; `fsync` waits for the drive to confirm.\n- Renames are metadata, so durability needs `fsync` on the **directory** too, not just the file.\nNEXT:\n? How does fdatasync differ from fsync?\n? What does O_DIRECT skip?",
  "follow": [
   {
    "q": "How does fdatasync differ from fsync?",
    "raw": "GIST: `fdatasync` skips the metadata flush, syncing only the ==data plus what's needed to read it back==.\n\n- `fsync` also writes mtime, atime and permissions; `fdatasync` skips those, so it's often faster on a busy file.\n- Both still flush the file's size if it changed — otherwise the new bytes would be unreachable.\n- Neither syncs the directory entry; a fresh file still needs `fsync` on the parent dir.\n\n```c\nfsync(fd);      // data + all metadata\nfdatasync(fd);  // data + size, skips mtime/atime\n```\n\nNEXT:\n? When is fdatasync unsafe to use?\n? Does O_DSYNC imply fdatasync semantics?"
   },
   {
    "q": "What does O_DIRECT skip?",
    "raw": "GIST: Opens a file so reads and writes ==bypass the page cache==, going straight between your buffer and the device.\n\n- You must supply **aligned** buffers and offsets (typically 512 or 4096 bytes), or the call fails with `EINVAL`.\n- It skips caching, not durability: you still need `fsync` for the data to be safe.\n- Databases use it to avoid double-buffering and to control exactly when I/O happens.\n\n```\nint fd = open(path, O_RDWR | O_DIRECT);\nposix_memalign(&buf, 4096, 4096);   // aligned buffer\npread(fd, buf, 4096, 0);            // aligned offset\n```\n\nNEXT:\n? Does O_DIRECT imply O_SYNC?\n? When is the page cache still worth it?"
   }
  ]
 },
 "flush": {
  "raw": "TERM: flush\nEXPANDS:\nKIND: I/O operation\nGIST: Hands your program's buffered bytes to the ==operating system==, not to the disk.\n- `fsync` goes further: it forces the kernel to push those bytes onto the physical medium, so only it makes data survive a power cut.\n- A flush is cheap and fast; an fsync is a real disk round-trip, which is why databases batch them.\nNEXT:\n? What does fsync actually wait for?\n? Why fsync the directory after a rename?",
  "follow": [
   {
    "q": "What does fsync actually wait for?",
    "raw": "GIST: It waits until the file's data and metadata are ==on stable storage==, so a power cut can't lose them.\n- On Linux it also flushes the file's metadata (size, timestamps); `fdatasync` skips the parts that don't affect reading the data back.\n- The call returns once the device reports the write complete — on a disk with a volatile write cache, that means the cache was flushed too.\n- It does **not** guarantee the directory entry exists; a new file can be fsynced yet vanish from the directory after a crash.\nNEXT:\n? When is fdatasync enough instead?\n? Does fsync flush other files' writes too?"
   },
   {
    "q": "Why fsync the directory after a rename?",
    "raw": "GIST: A rename only changes the ==directory entry==, so without an fsync on the directory that change can vanish in a crash.\n- `fsync` on the file flushes the file's *contents*; it says nothing about the directory entry pointing at it.\n- So a crash can leave the new file's data safely on disk but the old name still in place — the rename is undone.\n- The directory is itself a file; fsync it to make the new entry durable.\n\n```c\nint dfd = open(dir, O_RDONLY);\nfsync(fd_of_new_file);   // data is safe\nrename(tmp, final);      // entry swapped\nfsync(dfd);              // entry is safe\n```\n\nNEXT:\n? Does ext4 need this, or only some filesystems?\n? What about creating a file, not renaming?"
   }
  ]
 },
 "fsyncdir": {
  "raw": "TERM: fsyncing the directory\nEXPANDS:\nKIND: filesystem operation\nGIST: Flushing a directory's own metadata to disk so a rename inside it ==survives a power cut==.\n- `fsync` on a file persists its contents; `fsync` on the directory persists the **rename** or create that put it there.\n- Without it the file's data can be durable while the name pointing to it is not — you lose the new file, not just its bytes.\nNEXT:\n? Does ext4 need this after a rename?\n? How do I fsync a directory in Go?",
  "follow": [
   {
    "q": "Does ext4 need this after a rename?",
    "raw": "GIST: Yes — ext4 does not guarantee a rename is durable until you ==fsync the directory==, even with `auto_da_alloc`.\n\n- `auto_da_alloc` only forces data out on the *replace* pattern (write temp, rename over existing), and it's a heuristic, not a durability promise.\n- `data=ordered` (the default) orders data before metadata, but the rename's directory entry still needs its own flush.\n- Mount options like `barrier=0` or `nobarrier` weaken this further; don't rely on them for a store.\n\n```c\nint dfd = open(dir, O_RDONLY | O_DIRECTORY);\nfsync(dfd);   /* persists the rename */\nclose(dfd);\n```\n\nNEXT:\n? Does XFS or btrfs need it too?\n? What does `auto_da_alloc` actually do?"
   },
   {
    "q": "How do I fsync a directory in Go?",
    "raw": "Open the directory with `os.Open` and call `Sync()` on it — ==a directory is just an fd you can fsync==.\n\n```go\nd, err := os.Open(dir)\nif err != nil { return err }\ndefer d.Close()\nreturn d.Sync()\n```\n\n- `os.Open` is enough; you don't need write permission to fsync a directory's metadata.\n- On Linux this maps to `fsync(2)` on the dirfd; on macOS it works too, but APFS is more forgiving about ordering.\n- Do it **after** the rename, and check the error — a failed dir fsync means the rename may not be durable.\nNEXT:\n? Does Windows need a directory fsync?\n? How does SQLite handle this?"
   }
  ]
 },
 "lru": {
  "raw": "TERM: LRU\nEXPANDS: Least Recently Used\nKIND: cache policy\nGIST: Eviction rule that discards the ==least recently touched== entry first when the cache is full.\n- A full table scan touches every block once, so it **evicts** the hot working set — the classic scan-pollution problem.\n- Alternatives like LRU-K or clock/2Q resist this by tracking frequency, not just recency.\nNEXT:\n? How do databases defend against scan pollution?\n? What is clock or 2Q eviction?",
  "follow": [
   {
    "q": "How do databases defend against scan pollution?",
    "raw": "GIST: They keep scans from ==evicting the hot set== by marking scan reads as low-priority or bypassing the cache entirely.\n\n- **Buffer ring / small pool**: a scan gets a tiny dedicated slice of buffers, so it recycles only its own pages.\n- **Touch-on-second-hit**: pages enter a probation queue and are promoted only when read again (2Q, LRU-K, clock).\n- **Direct I/O or `O_DIRECT`**: big sequential reads skip the page cache, leaving resident pages untouched.\n\nNEXT:\n? How does PostgreSQL's ring buffer work?\n? What is the clock eviction algorithm?"
   },
   {
    "q": "What is clock or 2Q eviction?",
    "raw": "GIST: Two LRU approximations that resist scan pollution: ==clock== sweeps a circular buffer with reference bits, ==2Q== splits entries into a probation queue and a protected queue.\n\n- Clock: each page has a use bit; the hand clears bits and evicts the first zero it finds — cheap, no list surgery per hit.\n- 2Q: new entries land in a FIFO probation queue; only a second hit promotes them to the LRU-protected queue, so one-touch scan blocks never displace hot data.\n- Both are **approximations** — real LRU needs a linked list and a pointer update on every access, which is too costly under a lock.\n\n```\nhand →  [A:1] [B:0] [C:1] [D:0]\n        clear A, skip; B is 0 → evict B\n```\n\nNEXT:\n? How does ARC differ from 2Q?\n? What does Postgres actually use for its buffer cache?"
   }
  ]
 },
 "mvcc": {
  "raw": "TERM: MVCC\nEXPANDS: Multiversion Concurrency Control\nKIND: concurrency control\nGIST: Readers see a ==snapshot of old row versions== instead of locking rows, so they never block writers.\n- Each write creates a new row version rather than overwriting; the old ones are what \"pile up\" until `vacuum` reclaims them.\n- Contrast with plain locking (2PL): no read locks, but you pay in storage and cleanup — hence the vacuum pressure.\nNEXT:\n? How does Postgres vacuum reclaim dead rows?\n? What is a snapshot isolation anomaly?",
  "follow": [
   {
    "q": "How does Postgres vacuum reclaim dead rows?",
    "raw": "VACUUM scans heap pages and marks space left by ==dead tuples== as reusable, then updates the visibility map so future scans can skip them.\n- A tuple is dead once no active snapshot can see it; `VACUUM` only removes those, so long-running transactions hold it back.\n- Plain `VACUUM` frees space for reuse *within* the table; only `VACUUM FULL` rewrites the file and returns space to the OS — and it takes an exclusive lock.\n- `autovacuum` triggers on dead-tuple thresholds; if it can't keep up, tables bloat and indexes carry pointers to dead rows until cleaned.\n\n```\nVACUUM (VERBOSE, ANALYZE) my_table;   -- reclaim + refresh stats\nVACUUM FULL my_table;                 -- rewrite, exclusive lock\n```\n\nNEXT:\n? What is the visibility map used for?\n? Why do long transactions block vacuum?"
   },
   {
    "q": "What is a snapshot isolation anomaly?",
    "raw": "Snapshot isolation lets each transaction read from a ==consistent snapshot taken at its start==, but it permits anomalies serializability would forbid.\n- **Write skew**: two transactions read overlapping data, each writes a different row, and both commit — no conflict detected because they never wrote the same row.\n- Classic example: two doctors on call both check \"is another doctor on call?\" see yes, and both go off duty — leaving none.\n- Also allows read-only transactions to see a state that never existed as a committed instant, since snapshots can be stale.\nNEXT:\n? How does serializable snapshot isolation fix write skew?\n? What is a lost update under SI?"
   }
  ]
 },
 "vacuum": {
  "raw": "TERM: vacuum\nEXPANDS:\nKIND: database maintenance\nGIST: Background process that reclaims storage from dead row versions MVCC leaves behind.\n- In Postgres, `VACUUM` marks space reusable; `VACUUM FULL` rewrites the table and takes an exclusive lock.\n- If it lags, tables and indexes bloat, and transaction ID wraparound becomes a risk.\nNEXT:\n? How does autovacuum decide when to run?\n? What is transaction ID wraparound?",
  "follow": [
   {
    "q": "How does autovacuum decide when to run?",
    "raw": "Autovacuum triggers on a table once dead tuples exceed a ==threshold that scales with table size==, checked by the autovacuum launcher roughly every minute.\n\n- Formula: `autovacuum_vacuum_threshold` (default 50) + `autovacuum_vacuum_scale_factor` (default 0.2) × live tuples. So a 1M-row table waits for ~200,050 dead rows.\n- The 0.2 scale factor is why big tables bloat badly; set a per-table `autovacuum_vacuum_scale_factor` like 0.01 for hot, high-churn tables.\n- Inserts also count: `autovacuum_vacuum_insert_threshold` (default 1000) triggers vacuum on insert-only tables so visibility maps stay current.\n\n```\n-- per-table override\nALTER TABLE events SET (\n  autovacuum_vacuum_scale_factor = 0.01,\n  autovacuum_vacuum_threshold = 1000\n);\n```\n\nNEXT:\n? How do I see what autovacuum is doing now?\n? When should I run VACUUM FULL instead?"
   },
   {
    "q": "What is transaction ID wraparound?",
    "raw": "GIST: Postgres assigns each transaction a 32-bit ID, and after ~4 billion of them the counter ==wraps around==, making old rows look newer than new ones.\n\n- Rows are visible if their XID is \"in the past\"; wrap breaks that comparison, so ancient data can silently vanish or reappear.\n- Postgres forces a `VACUUM FREEZE` to mark old rows as permanently frozen before the limit is hit — if vacuum can't keep up, it refuses new writes.\n- The hard stop is ~2 billion transactions after the last freeze, not 4 billion; the margin is the safety buffer.\n\n```\nwraparound at 2^32 XIDs\nfreeze old rows → they're \"always visible\"\nfall behind → \"database is not accepting commands\"\n```\n\nNEXT:\n? How do I check how close we are?\n? Why does freezing prevent wraparound?"
   }
  ]
 },
 "memo": {
  "raw": "TERM: memoisation\nEXPANDS: \nKIND: caching technique\nGIST: Caching a function's result keyed by its inputs so repeat calls ==skip the work==.\n- Distinct from the block cache here: that's LRU over disk pages, this is a **per-call** result store, often unbounded.\n- Classic gotcha: stale entries — if the planner's inputs change but the key doesn't, it returns an old plan.\nNEXT:\n? How does memoisation differ from caching?\n? Why would a query planner memoise plans?",
  "follow": [
   {
    "q": "How does memoisation differ from caching?",
    "raw": "GIST: Caching is the general idea of storing anything for reuse; memoisation is the specific case of ==caching a function's return value keyed by its arguments==.\n\n- A cache is usually a bounded store you manage (evict, expire, invalidate); memoisation is often just a map that grows forever.\n- Memoisation is transparent — same function, same signature, no caller changes. A cache usually means the caller asks a cache instead of the source.\n- Both share the same failure: if the underlying data changes but the key doesn't, you serve a stale answer.\n\nNEXT:\n? When should I bound a memo table?\n? Is memoisation the same as dynamic programming?"
   },
   {
    "q": "Why would a query planner memoise plans?",
    "raw": "GIST: To avoid re-deriving a plan for the same subquery shape, the planner ==caches the plan keyed by the query's structure==.\n\n- Join-order search is combinatorial; memoising subplans turns exponential re-exploration into a lookup.\n- The key is usually the normalised query tree plus stats version — if stats change but the key doesn't, you get a **stale** plan.\n- That's exactly the failure mode in your review: plans go stale because the cache isn't invalidated when row counts or indexes shift.\n\nNEXT:\n? How do planners invalidate memoised plans?\n? What's a plan cache vs a prepared statement?"
   }
  ]
 },
 "glasswing": {
  "search": "Glasswing security",
  "raw": "TERM: Glasswing\nEXPANDS: \nKIND: security program\nGIST: Anthropic's ==Project Glasswing== gives select companies and maintainers access to its Mythos model to hunt software vulnerabilities.\n- Launched April 2026 with 11 organisations, later widened to a consortium; the model shipped publicly as Claude Mythos 5 in June.\n- It's the program, not the model — Mythos does the scanning, Glasswing is who gets it early.\nNEXT:\n? How does Mythos find vulnerabilities?\n? Who was in the first 11?",
  "sources": [
   {
    "name": "Claude Mythos",
    "url": "https://en.wikipedia.org/wiki/Claude_Mythos"
   },
   {
    "name": "Claude (AI)",
    "url": "https://en.wikipedia.org/wiki/Claude_(AI)"
   }
  ],
  "follow": [
   {
    "q": "How does Mythos find vulnerabilities?",
    "raw": "GIST: Mythos reads source code and reasons about it like a security researcher, ==spotting exploitable patterns== rather than matching known signatures.\n\n- It's a language model, so it generalises: it can flag a novel bug class in unfamiliar code, not just CVEs it has seen.\n- The Glasswing setup pairs it with human triage — findings get reported and fixed, so it's assistive, not autonomous patching.\n- Expect false positives; the value is in coverage of code nobody has audited, not in replacing a fuzzer or static analyser.\nNEXT:\n? How does it compare to fuzzing?\n? What did Glasswing find first?"
   },
   {
    "q": "Who was in the first 11?",
    "raw": "GIST: The named participants aren't in what I have — reports say ==11 companies and organisations==, but the roster itself isn't something I can confirm.\n\n- Public write-ups describe the group as a mix of large tech firms and open-source maintainers; no reliable list of names.\n- Anthropic's own announcement would be the source of record for who was included.\n\nNEXT:\n? What did the 11 get access to?\n? How did Glasswing become a wider consortium?"
   }
  ]
 }
};
