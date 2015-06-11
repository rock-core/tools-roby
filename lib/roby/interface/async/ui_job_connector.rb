module Roby
    module Interface
        module Async
            class UIJobConnector
                # The underlying UI connector
                attr_reader :connector
                # The action name
                attr_reader :action_name
                # The arguments that are part of the job definition itself
                attr_reader :static_arguments
                # The arguments that are set through the GUI
                attr_reader :arguments
                # The underlying {JobMonitor} object
                attr_reader :async

                # The list of progress monitors
                #
                # @return [Array<UIConnector::ProgressMonitor>]
                attr_reader :progress_monitors

                def interface
                    connector.interface
                end

                def exists?
                    !!async
                end

                def terminated?
                    async && async.terminated?
                end

                def job_id
                    async && async.job_id
                end

                def initialize(connector, action_name, static_arguments = Hash.new)
                    @connector, @action_name, @static_arguments =
                        connector, action_name, static_arguments
                    @arguments = Hash.new
                    @progress_monitors = Array.new

                    interface.on_reachable do
                        update_progress_monitors
                    end
                    interface.on_unreachable do
                        unreachable!
                    end
                    interface.on_job(action_name: action_name) do |job|
                        if !self.async || self.job_id != job.job_id || terminated?
                            matching = static_arguments.all? do |arg_name, arg_val|
                                job.task.action_arguments[arg_name,to_sym] == arg_val
                            end
                            if matching
                                self.async = job
                                job.start
                            end
                        end
                    end
                end

                def running?
                    async && async.running?
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
                    update_progress_monitors
                end

                def async=(async)
                    @async = async
                    async.on_progress do
                        if self.async == async
                            update_progress_monitors
                        end
                    end
                    update_progress_monitors
                end

                def update_progress_monitors
                    progress_monitors.each do |monitor|
                        monitor.update
                    end
                end

                def kill
                    async && async.kill
                end
            end
        end
    end
end

