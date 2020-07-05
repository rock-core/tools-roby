# frozen_string_literal: true

module Roby
    module Interface
        # A task service that is used to tag tasks that are job in the plan.
        # Only the tasks that provide Job, are missions and have a non-nil
        # {#job_id} argument are proper jobs.
        task_service "Job" do
            # The job ID
            #
            # If non-nil, it is used to refer to the job in various Interface
            # APIs. Otherwise, the task will not be considered a proper job at
            # all
            #
            # It is nil by default if Conf.app.auto_allocate_job_ids? is false
            # )which is the default). Otherwise, {#initialize} will
            # auto-allocate a job ID using {#allocate_job_id}.
            #
            # @return [Integer,nil]
            argument :job_id, default: nil

            def self.allocate_job_id
                @@job_id += 1
            end
            @@job_id = 0

            # Automatically allocate a job ID
            #
            # @return [Integer]
            def allocate_job_id
                self.job_id ||= Job.allocate_job_id
            end

            # @return [String] the job name as should be displayed by the job
            #   management API
            def job_name
                to_s
            end

            def initialize(**)
                super
                if Conf.app.auto_allocate_job_ids? && !job_id
                    allocate_job_id
                end
            end
        end
    end
end
