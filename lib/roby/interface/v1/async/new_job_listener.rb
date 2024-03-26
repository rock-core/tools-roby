# frozen_string_literal: true

module Roby
    module Interface
        module V1
            module Async
                # Listener object for {Interface#on_job}
                class NewJobListener
                    # @return [Interface] the interface we are connected to
                    attr_reader :interface
                    # @return [String,nil] the name of the action whose job we are
                    #   tracking. If nil, tracks all actions.
                    attr_reader :action_name
                    # @return [#call] the notification callback
                    attr_reader :block

                    # The set of job IDs that have already been processed
                    attr_reader :processed_job_ids

                    def initialize(interface, action_name, block)
                        @interface = interface
                        @action_name = action_name
                        @block = block
                        @processed_job_ids = Set.new
                    end

                    # Resets the listener so that it can be used on a new connection
                    def reset
                        @processed_job_ids = Set.new
                    end

                    # Tests whether this listener has already seen the job with the
                    # given ID
                    #
                    # @param [Integer] job_id
                    def seen_job_with_id?(job_id)
                        @processed_job_ids.include?(job_id)
                    end

                    # Tests whether the provided job matches what this listener
                    # wants
                    def matches?(job)
                        !action_name || (job.action_name == action_name)
                    end

                    # Call the listener for the given job
                    #
                    # @param [JobMonitor] job
                    def call(job)
                        @processed_job_ids << job.job_id
                        block.call(job)
                    end

                    # Tell the listener that the given job has been
                    #
                    # This is needed so that the processed_job_ids does not grow
                    # forever
                    def clear_job_id(job_id)
                        @processed_job_ids.delete(job_id)
                    end

                    # Tell this listener that the given job was received, but
                    # ignored.
                    #
                    # This is an optimization to avoid re-considering this listener
                    # for the given job
                    def ignored(job)
                        @processed_job_ids << job.job_id
                    end

                    # Start listening for jobs
                    def start
                        interface.add_new_job_listener(self)
                    end

                    # Stop listening for jobs
                    def stop
                        interface.remove_new_job_listener(self)
                    end
                end
            end
        end
    end
end
