require 'qtwebkit'

class Roby::Task::DRoby
    attr_accessor :mission
end

module Roby
    module LogReplay
	class Notifications < DataDecoder
	    GENERATOR_CALL_LIMIT = 0.1

            attr_reader :manager
	    attr_reader :tasks
            attr_reader :transactions

	    attr_reader :histories
	    def initialize(name)
                @manager = ObjectIDManager.new
                @transactions = ValueSet.new
		@histories = Hash.new { |h, k| h[k] = Array.new }
		super(name)
	    end

            def added_transaction(trsc)
                transactions << manager.local_object(trsc)
            end
            def removed_transaction(trsc)
                local_obj = manager.remove(trsc)
                transactions.delete(local_obj)
            end

	    def added_task(task)
                manager.local_object(task)
	    end
	    def removed_task(remote_id)
                manager.remove(remote_id)
	    end

	    def clear
		super

		@histories.clear
	    end


	    def process(data)
		data.each_slice(4) do |m, sec, usec, args|
                    m = m.to_s
		    time = Time.at(sec, usec)
		    case m.to_s
                    when /added_transaction/
                        plan, trsc = args[0], args[1]
                        added_transaction(trsc)

		    when /added_mission/
                        plan, task = args[0], args[1]
                        plan = manager.local_object(plan)
                        next if transactions.include?(plan)

			task = manager.local_object(task)
			task.mission = true
			event :added_mission, time, plan, task

		    when /unmarked_mission/
                        plan, task = args[0], args[1]
                        plan = manager.local_object(plan)
                        next if transactions.include?(plan)

			task = manager.local_object(args[1])
			task.mission = false
			event :unmarked_mission, time, plan, task

		    when /added_tasks/
			args[1].each { |t| added_task(t) }

		    when /finalized_task/
                        plan, task = args[0], args[1]
                        plan = manager.local_object(plan)
                        next if transactions.include?(plan)

			task = manager.local_object(task)
			if histories[task].empty?
			    event :finalized_pending, time, plan, task
			end
			histories.delete(task)
			removed_task(task)

		    when /generator_calling/
			@current_call = [time, args[0]]

		    when /generator_called/
			if @current_call[1] == args[0]
			    duration = time - @current_call[0]
			    if duration > GENERATOR_CALL_LIMIT
				event :overly_long_call, time, duration, tasks[args[0].task], args[0].symbol, args[1]
			    end
			end
			
		    when /exception/
			error, involved_tasks = *args
			involved_tasks = involved_tasks.map do |id|
                            manager.local_object(id)
                        end
			event m, time, error, involved_tasks

		    when /generator_fired/
			generator = args[0]
			if generator.respond_to?(:task)
                            task = manager.local_object(generator.task)
			    histories[task] << args
			    if generator.symbol == :failed
				event :failed_task, time, task, histories[task]
			    end
			end
		    end
		end
	    end

	    def event(name, *args)
		displays.each do |display|
		    if display.respond_to?(name)
			display.send(name, *args)
		    end
		end
	    end
	end

	class NotificationsDisplay < Qt::WebView
	    include DataDisplay
	    decoder Notifications

	    attr_reader :document
	    attr_reader :text

	    STYLESHEET = <<-EOS
		    h1 { font-size: 100%; }
		    h1 { margin-bottom: 3px; }
		    .time { 
			margin-right: 10px; 
		    }

		    div.info {
			color: black;
			margin-top: 20px;
			border-top: thin solid black;
		    }
		    div.info h1 { margin-top: 0; background-color: #5FB86A; }
		    div.warn { 
			color: black;
			margin-top: 20px;
			border-top: thin solid black; 
		    }
		    div.warn h1 { margin-top: 0; background-color: #B8AC5F; }
		    div.error { 
			color: black;
			margin-top: 20px;
			border-top: thin solid black; 
		    }
		    div.error h1 { margin-top: 0; background-color: #B8937D; }
	    EOS

	    def initialize
		super()

		resize(500, 600)
		@main     = self
                @text = ""
	    end


	    def render_event(kind, time, title)
		text << "\n<div class=\"#{kind}\">\n  <h1><span class=\"time\">#{time.to_hms}</span> #{title}</h1>\n"
		yield

	    ensure
		text << "\n</div>"

                html = "<html><style>#{STYLESHEET}</style><body>#{text}</body></html>"
		setHtml(html)
                main_frame = page.main_frame
                max = main_frame.scroll_bar_maximum(Qt::Vertical)
                main_frame.set_scroll_bar_value(Qt::Vertical, max)
	    end

	    def render_task(task)
		remote_siblings = "{ " << task.remote_siblings.map { |peer, id| id.to_s(peer) }.join(", ") << " }"
		text << "  <div class=\"task\">#{task.model.ancestors.first.first}#{remote_siblings}\n"
		
		unless task.arguments.empty?
		    text << "      <ul class=\"task-arguments\">\n"
		    task.arguments.each do |key, value|
			text << "        <li>#{key}: #{value}</li>\n"
		    end
		    text << "      </ul>\n"
		end
		text << "  </div>"
	    end

	    def render_history(history)
		text << "<ul class=\"history\">\n"
		history.each do |generator, id, time, context|
		    text << "<li>#{time.to_hms} #{generator.symbol} [#{context}]</li>"
		end
		text << "</ul>"
	    end

	    def clear
		setHtml("")
	    end

	    def finalized_pending(time, plan, task)
		render_event("warn", time, "Finalized pending task") do
		    render_task(task)
		end
	    end
	    def added_mission(time, plan, task)
		render_event("info", time, "New mission") do
		    render_task(task)
		end
	    end
	    def removed_mission(time, task)
		render_event("info", time, "Removed mission") do
		    render_task(task)
		end
	    end
	    def render_error(error, tasks)
		error = Qt.escape(error.to_s)
		error = error.split("\n").map do |line|
		    line.gsub(/^\s+/) { "&nbsp;" * $&.size }
		end.join("<br>")

		text << error
		text << "<h2>Involved tasks</h2>"
		text << "<ul>"
		tasks.each do |t| 
		    text << "<li>"
		    render_task(t) 
		    text << "</li>"
		end
	    end

	    def fatal_exception(time, error, tasks)
		render_event("error", time, "Fatal exception") do
		    render_error(error, tasks)
		end
	    end
	    def handled_exception(time, error, tasks)
		render_event("warn", time, "Handled exception") do
		    render_error(error, tasks)
		end
	    end
	    def failed_task(time, task, history)
		render_event("warn", time, "Failed task") do
		    render_task(task)
		    render_history(history)
		end
	    end
	    def overly_long_call(time, duration, task, event_name, context)
		render_event("warn", time, "Overly long call: ") do
		    text << "Call of #{event_name}(#{context}) lasted #{Integer(duration * 1000)}ms in<br>"
		    render_task(task)
		end
	    end
	end
    end
end

