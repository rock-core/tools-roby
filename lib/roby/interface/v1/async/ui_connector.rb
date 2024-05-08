# frozen_string_literal: true

module Roby
    module Interface
        module V1
            module Async
                # Creates a connection between a Syskit job and a Qt-based GUI
                #
                # A job is a placeholder for an action with some arguments set. It
                # is created by {Interface#connect_to_ui}. More than one job can exist
                # based on a given action (as long as they differ by their
                # arguments), but a given job can be started by the GUI only once.
                #
                # @example represent an action with some argument(s) set
                #   action = <name_of_action>!(x: 10)
                #
                # @example start a job from an action when a button is pressed
                #   connect widget, SIGNAL('clicked()'), START(action)
                #
                # @example allow a job to be restarted (otherwise an existing job must be manually killed first)
                #   connect widget, SIGNAL('clicked()'), START(action), restart: true
                #
                # @example kill the job when a button is pressed
                #   connect widget, SIGNAL('clicked()'), KILL(action)
                #
                # @example call a block with a job monitoring object when its state changes
                #   connect PROGRESS(job) do |action|
                #      # 'action' is an ActionMonitor
                #   end
                #
                # @example set an action's argument from a signal (by default, requires the user to press the 'start' button afterwards)
                #   connect widget, SIGNAL('textChanged(QString)'), ARGUMENT(action,:z),
                #      getter: ->(z) { Integer(z) }
                #
                # @example set an action's argument from a signal, and restart the action right away
                #   connect widget, SIGNAL('textChanged(QString)'), ARGUMENT(action,:z),
                #      getter: ->(z) { Integer(z) },
                #      auto_apply: true
                class UIConnector
                    ActionConnector = Struct.new :connector, :action, :options do
                        def interface
                            connector.interface
                        end
                    end

                    class StartCommand < ActionConnector
                        def run
                            if !options[:restart] && action.exists? && !action.terminated?
                                return
                            end

                            action.restart
                        end
                    end

                    class DropCommand < ActionConnector
                        def run
                            if action.exists? && !action.terminated?
                                action.drop
                            end
                        end
                    end

                    class KillCommand < ActionConnector
                        def run
                            if action.exists? && !action.terminated?
                                action.kill
                            end
                        end
                    end

                    class SetArgumentCommand < ActionConnector
                        attr_reader :argument_name

                        def initialize(connector, action, argument_name, getter: nil)
                            super(connector, action, getter: getter)
                            @argument_name = argument_name.to_sym
                        end

                        def run(arg)
                            if (getter = options[:getter])
                                arg = getter.call(arg)
                                unless arg
                                    Interface.warn "not setting argument #{action}.#{argument_name}: getter returned nil"
                                    return
                                end
                            end
                            action.arguments[argument_name] = arg
                            if options[:auto_apply]
                                StartAction.new(connector, action, restart: true).run
                            end
                        end
                    end

                    class ProgressMonitorCommand < ActionConnector
                        attr_accessor :callback

                        def connect
                            action.on_progress do
                                update
                            end
                        end

                        def update
                            callback.call(action)
                        end
                    end

                    attr_reader :interface, :widget

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
                            action.options = args.shift || {}
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

                    def START(action)
                        StartCommand.new(self, action)
                    end

                    def DROP(action)
                        DropCommand.new(self, action)
                    end

                    def KILL(action)
                        KillCommand.new(self, action)
                    end

                    def PROGRESS(action)
                        ProgressMonitorCommand.new(self, action)
                    end

                    def ARGUMENT(action, argument_name)
                        SetArgumentCommand.new(self, action, argument_name)
                    end

                    def respond_to_missing?(m, include_private = false)
                        (m =~ /!$/) || widget.respond_to?(m) || super
                    end

                    def method_missing(m, *args, &block)
                        if m =~ /!$/
                            ActionMonitor.new(interface, m.to_s[0..-2], *args)
                        elsif widget.respond_to?(m)
                            widget.public_send(m, *args, &block)
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
end
