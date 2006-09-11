require 'roby/log/relation-server'

module Roby::Display
    # Displays the plan's causal network
    class TaskStructureServer < RelationServer
	def relation_object_pos(task_id)
	    canvas_item = canvas_task(tasks[task_id]).canvas_item[:rectangle]
	    [canvas_item.x + canvas_item.width / 2, canvas_item.y + canvas_item.height / 2]
	end
	def relation_object(id)
	    tasks[id]
	end
	def define_relation_object(task)
	    task(task)
	end
	alias :each_task_relation :each_relation
    end
end


