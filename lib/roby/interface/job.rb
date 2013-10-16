module Roby
    module Interface
        task_service 'Job' do
            argument :job_id, :default => nil

            def self.allocate_job_id
                @@job_id += 1
            end
            @@job_id = 0
        end
    end
end

