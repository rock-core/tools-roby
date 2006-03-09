require 'roby/task'

module Roby::TaskStructure
    task_relation ExecutedBy do
        def initialize
            if self.class.execution_agent
                executed_by self.class.execution_agent.new_task(self)
            end
            super
        end

        def self.included(klass)
            class << klass
                attr_reader :execution_agent
                # Defines a model of execution agent
                # model.new_task(task) shall return the task instance which
                # will execute this task 
                def executed_by(model)
                    @execution_agent = agent
                end
            end
            super
        end
        
	def execution_agent; children[ExecutedBy].find { true } end
        def executed_by(agent)
            raise "an agent is already defined for this task" if execution_agent
	    add_relation(ExecutedBy, agent, nil)
            realized_by agent, :fails_on => :stop
        end
    end
end


