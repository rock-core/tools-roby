require 'roby/task'
require 'roby/relations/hierarchy'

module Roby::TaskStructure
    relation ExecutedBy do
	relation_name :execution_agent

        def initialize
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
        
	def execution_agent; enum_for(:each_execution_agent).find { true } end
        def executed_by(agent)
            raise "an agent is already defined for this task" if execution_agent
	    add_relation(ExecutedBy, agent, nil)
            realized_by agent, :fails_on => :stop
        end
    end

    Hierarchy.superset_of ExecutedBy
end


