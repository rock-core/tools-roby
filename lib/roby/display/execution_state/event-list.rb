
class Roby::ExecutionStateDisplayServer
    class EventList < Qt::ListView
	attr_reader :pending

	class Task < Qt::ListViewItem
	    def initialize(view, task)
		super(view)
		set_text(0, task.model.name << " 0x" << task.source_address.to_s(16))
	    end
	end

	class Event < Qt::ListViewItem
	    def event_name(event, with_task = true)
		expr = ""

		if event.respond_to?(:task) && with_task
		    expr << event.task.source_class.to_s
		end

		if event.respond_to?(:symbol)
		    expr << "[" << event.symbol.to_s << "]"
		else
		    expr << event.model.name
		end

		expr.gsub!(/^Roby::(?:Genom::)?/, '') 
		expr << " 0x" << event.source_address.to_s(16)
	    end


	    def initialize(list, task, kind, time, obj, *args)
		super(list)
		set_text(0, "%02i:%02i:%03i" % [time.tv_sec / 60, time.tv_sec % 60, time.tv_usec / 1000])
		if task
		    set_text(1, task.model.name)
		else
		    set_text(1, "toplevel")
		end
		set_text(2, kind.to_s)

		expr = event_name(obj, false)

		case kind
		when :signal
		    dest = *args
		    expr << " -> " << event_name(dest)
		when :postponed
		    wait_for, reason = *args
		    expr << " waiting for " << event_name(wait_for) << ": " << reason
		when :fired
		    context = args.first.context
		    unless context.empty?
			expr << ": " << context
		    end
		end
		set_text(3, expr)
	    end
	end

	def initialize(parent)
	    super(parent)
	    self.root_is_decorated = true
	    add_column "at"
	    add_column "in"
	    add_column "kind"
	    add_column "events"
	    @pending = Hash.new
	end

	def item_parent(generator)
	    if generator.respond_to?(:task)
		pending[generator.task] ||= Task.new(self, generator.task)
	    else
		self
	    end
	end

	def new_event(kind, time, generator, *args)
	    @reference ||= time
	    offset = time - @reference
	    time = Time.at(offset.to_i, (offset - offset.to_i) * 1000000)

	    task = generator.task if generator.respond_to?(:task)
	    Event.new(self, task, kind, time, generator, *args)
	end
	def pending_event(time, generator)
	    new_event(:pending, time, generator)
	end
	def fired_event(time, generator, event)
	    new_event(:fired, time, generator, event)
	end
	def signalling(time, from, to)
	    new_event(:signal, time, from, to)
	end
	def postponed(time, generator, wait_for, reason)
	    new_event(:postponed, time, generator, wait_for, reason)
	end
    end
end
    

