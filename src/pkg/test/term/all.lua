-- nt.term — aggregate suite.  Requiring this pulls in every nt.term test
-- in dependency order (scheduler/codec/editor/renderer first, then the
-- end-to-end readline that composes them).  selftest.lua loads just this;
-- a new term suite is added here, not there.

require('test.term.sched')
require('test.term.vt')
require('test.term.edit')
require('test.term.render')
require('test.term.line')

-- Boot-only (live kernel objects: overlapped handles, events, real
-- pipes, a spawned process).  Pure suites above run on the host too;
-- these need MicroNT.
require('test.term.stream')
require('test.term.bridge')
