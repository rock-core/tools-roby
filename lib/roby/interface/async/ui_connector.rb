module Roby
    module Interface
        module Async
            # Creates a connection between a Syskit job and a Qt-based GUI
            #
            # A job is a placeholder for an action with some arguments set. It
            # is created by {Interface#connect_job}. More than one job can exist
            # based on a given action (as long as they differ by their
            # arguments), but a given job can be started by the GUI only once.
            #
            # @example create a new job
            #   job = <name_of_action>!(x: 10)
            #
            # @example start the job when a button is pressed
            #   connect widget, SIGNAL('clicked()'), START(job)
            #
            # @example allow a job to be restarted (otherwise the job must be killed first)
            #   connect widget, SIGNAL('clicked()'), START(job), restart: true
            #
            # @example kill the job when a button is pressed
            #   connect widget, SIGNAL('clicked()'), KILL(job)
            #
            # @example call a block with a job monitoring object when its state changes
            #   connect PROGRESS(job) do |job|
            #      # 'job' is a UIJobConnector
            #   end
            #
            # @example set a job's argument from a signal (by default, requires the user to press the 'start' button afterwards)
            #   connect widget, SIGNAL('textChanged(QString)'), ARGUMENT(job,:z),
            #      getter: ->(z) { Integer(z) }
            #
            # @example set a job's argument from a signal, and restart the job right away
            #   connect widget, SIGNAL('textChanged(QString)'), ARGUMENT(job,:z),
            #      getter: ->(z) { Integer(z) },
            #      auto_apply: true
            class UIConnector
                JobAction = Struct.new :connector, :job, :options do
                    def interface
                        connector.interface
                    end
                end

                class StartAction < JobAction
                    def run
                        batch = interface.client.create_batch
                        if job.exists? && !job.terminated?
                            return if !options[:restart]
                            batch.kill_job(job.job_id)
                        end

                        batch.send("#{job.action_name}!", job.static_arguments.merge(job.arguments))
                        job_id = batch.process.last
                        job.async = interface.monitor_job(job_id)
                    end
                end

                class KillAction < JobAction
                    def run
                        if job.exists? && !job.terminated?
                            job.kill
                        end
                    end
                end

                class SetArgumentAction < JobAction
                    attr_reader :argument_name
                    def initialize(connector, job, argument_name)
                        super(connector, job, Hash.new)
                        @argument_name = argument_name.to_sym
                    end

                    def run(arg)
                        if getter = options[:getter]
                            arg = getter.call(arg)
                            if !arg
                                Interface.warn "not setting argument #{job}.#{argument_name}: getter returned nil"
                                return
                            end
                        end
                        job.arguments[argument_name] = arg
                        if options[:auto_apply]
                            StartAction.new(connector, job, restart: true).run
                        end
                    end
                end

                class ProgressMonitor < JobAction
                    attr_accessor :callback

                    def connect
                        job.progress_monitors << self
                    end

                    def update
                        callback.call(job)
                    end
                end

                attr_reader :interface
                attr_reader :widget

                def initialize(interface, widget)
                    @interface = interface
                    @widget = widget
                end

                def on_reachable(&block)
                    interface.on_reachable(&block)
                end

                def on_unreachable(&block)
                    interface.on_unreachable(&block)
                end

                def connect(*args, &block)
                    if args.first.kind_of?(Qt::Widget)
                        # Signature from a widget's signal to Syskit
                        widget = args.shift
                        signal = args.shift
                        action = args.shift
                        action.options = args.shift || Hash.new
                        if widget.respond_to?(:to_widget)
                            widget = widget.to_widget
                        end
                        widget.connect(signal) do |*args|
                            action.run(*args)
                        end
                    else
                        # Signature from syskit to a block
                        action = args.shift
                        action.options = args.shift
                        action.callback = block
                        action.connect
                    end
                end

                def START(job)
                    StartAction.new(self, job)
                end

                def KILL(job)
                    KillAction.new(self, job)
                end

                def PROGRESS(job)
                    ProgressMonitor.new(self, job)
                end

                def ARGUMENT(job, argument_name)
                    SetArgumentAction.new(self, job, argument_name)
                end

                def respond_to_missing?(m, include_private = false)
                    (m.to_s =~ /!$/) || widget.respond_to?(m, include_private)
                end

                def method_missing(m, *args, &block)
                    m = m.to_s
                    if m =~ /!$/
                        UIJobConnector.new(self, m[0..-2], *args)
                    elsif widget.respond_to?(m)
                        widget.send(m, *args, &block)
                    else
                        super
                    end
                end

                def to_widget
                    widget
                end
            end
        end
    end
end

