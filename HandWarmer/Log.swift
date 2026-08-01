import os

/// The silicon boosters fail quietly by design: one that cannot run should cost
/// no heat, not take the session down. That leaves nothing to see when a
/// booster is switched on and does nothing, so the setup paths say so here.
///
/// Read a device run with:
///
///     log stream --device --predicate 'subsystem == "dk.delectosoft.handwarmer"'
let heatLog = Logger(subsystem: "dk.delectosoft.handwarmer", category: "boosters")
