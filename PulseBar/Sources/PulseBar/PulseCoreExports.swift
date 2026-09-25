// The app sees the kernel and its libraries everywhere without every file
// importing them. The dependencies only point one way: nothing in PulseCore,
// PulseRespond or PulseHarvest can import this target.
@_exported import PulseCore
@_exported import PulseHarvest
@_exported import PulseRespond
