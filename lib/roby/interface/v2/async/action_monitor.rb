# frozen_string_literal: true

module Roby
    module Interface
        module V2
            module Async
                # An action definition
                #
                # While {JobMonitor} represents a running / instanciated job, this
                # represents just an action with a set of argument. It binds
                # automatically to a matching running job if there is one.
                class ActionMonitor
                    # The underlying Async::Interface
                    attr_reader :interface
                    # The action name
                    attr_reader :action_name
                    # The arguments that are part of the job definition itself
                    attr_reader :static_arguments
                    # The arguments that have been set to override the static
                    # arguments, or set arguments not yet set in {#static_arguments}
                    attr_reader :arguments
                    # The underlying {JobMonitor} object if we're tracking a job
                    attr_reader :async

                    include Hooks
                    include Hooks::InstanceHooks

                    # @!method on_progress
                    #
                    #   Hooks called when self got updated
                    #
                    #   @return [void]
                    define_hooks :on_progress

                    # Whether there is a job matching this action monitor running
                    def exists?
                        !!async
                    end

                    # The job ID of the last job that ran
                    def job_id
                        async&.job_id
                    end

                    # The set of arguments that should be passed to the action
                    #
                    # It is basically the merged {#static_arguments} and
                    # {#arguments}
                    def action_arguments
                        static_arguments.merge(arguments)
                    end

                    # @api private
                    #
                    # Helper to handle the batch argument in e.g. {#kill} and
                    # {#restart}
                    def handle_batch_argument(batch)
                        if batch
                            yield(batch)
                        else
                            yield(batch = interface.create_batch)
                            batch.__process
                        end
                    end

                    # Drop this job
                    #
                    # @param [Client::BatchContext] batch if given, the restart
                    #   commands will be added to this batch. Otherwise, a new batch
                    #   is created and {Client::BatchContext#__process} is called.
                    def drop(batch: nil)
                        handle_batch_argument(batch) do |b|
                            b.drop_job(async.job_id)
                        end
                    end

                    # Kill this job
                    #
                    # @param [Client::BatchContext] batch if given, the restart
                    #   commands will be added to this batch. Otherwise, a new batch
                    #   is created and {Client::BatchContext#__process} is called.
                    def kill(batch: nil)
                        unless running?
                            raise InvalidState, "cannot kill a non-running action"
                        end

                        handle_batch_argument(batch) do |b|
                            b.kill_job(async.job_id)
                        end
                    end

                    # Start or restart a job based on this action
                    #
                    # @param [Hash] arguments the arguments that should be used
                    #   instead of {#action_arguments}
                    # @param [Client::BatchContext] batch if given, the restart
                    #   commands will be added to this batch. Otherwise, a new batch
                    #   is created and {Client::BatchContext#__process} is called.
                    def restart(
                        arguments = self.action_arguments, batch: nil, lazy: false
                    )
                        if lazy && running? && (arguments == async.action_arguments)
                            return
                        end

                        handle_batch_argument(batch) do |b|
                            if running?
                                kill(batch: b)
                            end
                            b.start_job(action_name, arguments)
                        end
                    end

                    def initialize(interface, action_name, static_arguments = {})
                        @interface, @action_name, @static_arguments =
                            interface, action_name, static_arguments
                        @arguments = {}

                        interface.on_reachable do
                            run_hook :on_progress
                        end
                        interface.on_unreachable do
                            unreachable!
                        end
                        interface.on_job(action_name: action_name) do |job|
                            if !self.async || self.job_id != job.job_id || terminated?
                                matching = static_arguments.all? do |arg_name, arg_val|
                                    job.action_arguments[arg_name.to_sym] == arg_val
                                end
                                if matching
                                    self.async = job
                                    job.start
                                end
                            end
                        end
                    end

                    def running?
                        async&.running?
                    end

                    def success?
                        async&.success?
                    end

                    def failed?
                        async&.failed?
                    end

                    def finished?
                        async&.finished?
                    end

                    def terminated?
                        async&.terminated?
                    end

                    def state
                        if interface.reachable?
                            if !async
                                :reachable
                            else
                                async.state
                            end
                        else
                            :unreachable
                        end
                    end

                    def unreachable!
                        @async = nil
                        run_hook :on_progress
                    end

                    def async=(async)
                        @async = async
                        async.on_progress do
                            if self.async == async
                                run_hook :on_progress
                            end
                        end
                        run_hook :on_progress
                    end
                end
            end
        end
    end
end
