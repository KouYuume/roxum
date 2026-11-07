const backend = @import("net/tcp.zig");

pub const Error = backend.Error;
pub const AcceptedSocket = backend.AcceptedSocket;
pub const Listener = backend.Listener;
pub const Socket = backend.Socket;
pub const Deadline = backend.Deadline;
pub const FiberWait = backend.FiberWait;

pub const PendingAccept = backend.PendingAccept;

pub const acceptPending = backend.acceptPending;
pub const setListenerNonBlocking = backend.setListenerNonBlocking;
pub const receiveAvailable = backend.receiveAvailable;
pub const bytesAvailable = backend.bytesAvailable;
pub const closeSocket = backend.closeSocket;
pub const shutdownWrite = backend.shutdownWrite;
pub const monotonicNanoseconds = backend.monotonicNanoseconds;
pub const setCloseOnExec = backend.setCloseOnExec;
pub const listenIpv4 = backend.listenIpv4;
pub const receiveUntil = backend.receiveUntil;
pub const sendAllUntil = backend.sendAllUntil;
pub const sendIovecsUntil = backend.sendIovecsUntil;
pub const sendIovecsAvailable = backend.sendIovecsAvailable;
pub const sendAvailable = backend.sendAvailable;
