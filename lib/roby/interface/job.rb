module Roby
    module Interface
        task_service 'Job' do
            argument :job_id, :default => nil

            def self.allocate_job_id
                @@job_id += 1
            end
            @@job_id = 0

            def allocate_job_id
                self.job_id ||= Job.allocate_job_id
            end

            def initialize(arguments = Hash.new)
                super
                if Conf.app.auto_allocate_job_ids? && !job_id
                    allocate_job_id
                end
            end
        end
    end
end

