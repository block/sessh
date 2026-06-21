Sessh processes are single-threaded. This is intended to make the codebase
easier to understand, test, and debug. In most cases sessh will not be
CPU-bound, so the benefits of introducing additional threads is limited. If we
do encounter cases where we're CPU bound, they can be addressed via additional
processes.

In order to be efficient with a single thread, sessh uses non-blocking IO. We
have a Dispatcher which understands how to schedule DispatchTasks. DispatchTasks
are annotated with their dependencies: i.e. which file descriptors they read/write
to (if any), and when they are allowed to run (if they are scheduled in the
future). These dependencies allow us to implement backpressure.

The Dispatcher maintains Source objects for each file descriptor being read
from and Sink objects for each file descriptor being written to.

Since we're single-threaded, the Dispatcher is global per-process and we don't
need to pass it around between functions.

Sink objects maintain queues of content. These are given priority above all
else: If they have any queued content then as soon as their file descriptor
becomes writable the Dispatcher will give them a chance to flush it. The sink
objects have a concept of watermark. When the watermark is exceeded then
DispatchTasks that depend on them will not be scheduled.

Source objects read a "unit" of content at a time. This unit might be an array
of bytes or a Frame. The Dispatcher will only allow a Source to run if its file
descriptor becomes readable AND there is a DispatchTask annotated with it (and
that DispatchTask's Sink/time dependencies are met).

DispatchTasks run when their dependencies are met: There is space in any Sink
they are annotated with, the content is buffered in any Source they read from,
and their timeout (if any) has elapsed. Eligible DispatchTasks are scheduled fairly;
round-robin DispatchTask dispatch is what prevents one always-ready path from
starving unrelated work in the same process.

DispatchTasks can be written as manual coroutines when needed: They can keep a
state field and switch upon its value. They can reset their state and/or
requeue themselves if repetition is needed.

stderr is the one exception. We use blocking IO to write to stderr so that we
can always write logs. If logs are being written anywhere other than stderr
then we still need to use non-blocking IO. The stderr exception allows us to
debug problems with non-blocking IO that would otherwise be quite difficult,
but it comes at the risk of blocking our sole thread so we must be very careful
that we limit how much we write to stderr in normal circumstances.

To ensure we don't use blocking operations accidentally we wrap all potentially
problematic calls so we can audit for direct usage of potentially problematic
calls. Things like sleep and wait should be avoided. It's okay to ask the
Dispatcher to call us back later. Polling (repeatedly scheduling in the future
until some condition is met) is discouraged, but it might be unavoidable in
some circumstances.

Blocking operations are placed behind a Blocking struct. Running the dispatcher
loop is itself a blocking operation. Only the main function is allowed to
create the Blocking type, and it must be passed around to each function that is
allowed to perform blocking operations. We need to have lint or some kind of
enforcement to ensure nothing else creates the Blocking type.

Before starting the dispatcher loop we must enqueue DispatchTasks. The dispatcher
loop returns an explicit result that distinguishes a requested exit from an
implicit exit caused by running out of DispatchTasks. The caller decides whether an
implicit exit is expected for that process or whether it indicates deadlock.
