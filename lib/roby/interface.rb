require 'roby'
module Roby
    # High-level command and control of a Roby controller
    #
    # The {Interface} module provides a high-level control interface to a
    # running Roby controller. It is the basis for all remote Roby UIs such as
    # the Syskit IDE or the Roby shell. The following documentation aims at
    # giving a bird eye's view of the module's structure
    #
    # == Jobs
    #
    # The high-level construct used in the Roby interface is the job. Jobs are
    # representation of the high-level goals that a user gave to the system. A
    # task represents a job if:
    #
    # - it provides the {Interface::Job} service
    # - it has a non-nil {Interface::Job#job_id} argument
    # - itself or its planned task is a mission
    #
    # In case a job task is a planning task, the job itself will be represented
    # by the job's planned task. Across the job-related APIs, one will see that
    # jobs are therefore associated with two tasks: the task or placeholder
    # task, and the job task itself.
    #
    # The interface APIs provide ways to track the progress of jobs. Each job
    # transition is represented by a Interface::JOB_* constant (e.g.
    # {Interface::JOB_READY}), and notifications are sent to remote endpoints
    # about the current state and progress of jobs.
    #
    # == Synchronous Client/Server API
    #
    # A Roby application will in most cases create an {Interface::Interface}
    # object, which is the endpoint for all interface-related matters. A
    # client/server mechanism allows to access the app's interface.
    # {Interface::Server} provides the server-side and {Interface::Client} the
    # client-side. Both classes are independent of the communication channel
    # used. The communication is based on marshalling and demarshalling of an
    # array that represents a method name and arguments on the
    # {Interface::Interface} class. The marshalling/demarshalling and the exact
    # packet format is left to the channel class given to Client and Server at
    # construction time (see below)
    #
    # The core of the method calls on {Interface::Client} are the calls
    # available on {Interface::Interface}. Check the latter to figure out what
    # you can do with the former. In addition, it supports starting actions (and
    # jobs) using an action_name!(arguments) syntax. This is meant as syntactic
    # sugar for use in interactive implementations, but one should use
    # {Interface::Interface#start_job} when starting jobs programmatically.
    #
    # In addition to the remote method calls, the Client API provides
    # notifications pushed by the interface:
    #
    # - {Interface::Client#pop_notification}: general log messages from
    #   {Application#notify}. By default, all log messages generated from {Robot}
    #   are forwarded this way
    # - {Interface::Client#pop_job_progress}: job progress
    # - {Interface::Client#pop_exception}: about exceptions
    #
    # == Asynchronous API
    #
    # To connect to the client/server API, one has to have a remote Roby app to
    # connect to. Moreoover, the API is really designed as a request/response
    # scheme, which is not a very nice format to build UIs from.
    #
    # For these, reasons, a higher level, event-based API has been built on top
    # of the client/server functionality. The main entrypoint for this
    # asynchronous API is {Interface::Async::Interface}. In addition to properly
    # handling (re)connections, this API provides also a nicer interface to job
    # tracking.
    #
    # Jobs are represented by {Async::JobMonitor} objects, which track the job
    # state and provide operations on them such as killing, dropping and
    # restarting them as well as registering hooks to track their progress. One
    # usually gets these job monitor objects by listening for new jobs using
    # {Async::Interface#on_job}.
    #
    # Note that in most cases, new job monitor objects are inactive (i.e. won't
    # get notifications) until you explicitely call {Async::JobMonitor#start} on
    # them. Whether this is the case or not is documented on each method that
    # return or yield a job monitor object.
    #
    # == Asynchronous log stream API
    #
    # In addition to the notifications provided by {Interface::Client}, one can
    # use the Roby logging to build a complete representation of a plan. The
    # {Interface::Async::Log} class gives easy-to-use access to such a rebuilt
    # plan, along with the ability to disconnect and reconnect to a remote
    # Roby app.
    #
    # == Event Loop Integration
    #
    # {Interface::Interface} hooks itself in the app's main event loop, as does
    # {Interface::TCPServer}. On the client side, processing is done in
    # {Interface::Client#poll} which therefore needs to be called periodically
    # within your app's main loop. In Qt, it usually means starting a timer
    #
    #     timer = Qt::Timer.new(self)
    #     timer.connect(SIGNAL('timeout()')) do
    #         client.poll
    #     end
    #
    # == Communication Channel
    #
    # {Interface::DRobyChannel} provides a default implementation, using the
    # DRoby marshalling/demarshalling for object-to-binary translation,
    # WebSockets for framing and a subclass of IO as the underlying
    # communication medium. The most common usage is to spawn a TCP server based
    # on this channel with {Interface::TCPServer}, and connect to it from the
    # client side with  {Interface.connect_with_tcp_to}. A Roby application
    # spawns such a server automatically by calling
    # {Roby::Application#setup_shell_interface} if
    # {Roby::Application#public_shell_interface?} is true.
    #

    module Interface
        DEFAULT_PORT = 20201

        extend Logger::Hierarchy

        module Async
            extend Logger::Hierarchy
        end
    end
end

require 'websocket'
require 'utilrb/hash'
require 'roby/interface/job'
require 'roby/interface/exceptions'
require 'roby/interface/command_argument'
require 'roby/interface/command'
require 'roby/interface/command_library'
require 'roby/interface/interface'
require 'roby/interface/droby_channel'
require 'roby/interface/server'
require 'roby/interface/client'
require 'roby/interface/subcommand_client'
require 'roby/interface/tcp'
require 'roby/interface/shell_client'
require 'roby/interface/shell_subcommand'
