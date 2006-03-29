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
                def executed_by(agent)
                    @execution_agent = agent
                end
            end
            super
        end

	def execution_agent; enum_for(:each_execution_agent).find { true } end
        def executed_by(agent)
	    if execution_agent
		Roby.debug "an agent is already defined for this task"
		remove_execution_agent(execution_agent)
	    end

	    add_execution_agent(agent)
        end
    end

    Hierarchy.superset_of ExecutedBy
end


