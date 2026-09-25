// The app sees the kernel and its libraries everywhere without every file
// importing them. The dependencies only point one way: no library target can
// import this one.
@_exported import PulseCore
@_exported import PulseHarvest
@_exported import PulseManaged
@_exported import PulseRespond
