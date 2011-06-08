module Roby
    module LogReplay
        # This widget displays information about the event history in a list,
        # allowing to switch between the "important events" in this history
        class PlanRebuilderWidget < Qt::Widget
            attr_reader :list
            attr_reader :layout
            attr_reader :history
            attr_reader :plan_rebuilder
            attr_reader :current_plan
            attr_reader :displays

            def initialize(parent, plan_rebuilder)
                super(parent)
                @list    = Qt::ListWidget.new(self)
                @layout  = Qt::VBoxLayout.new(self)
                @history = Hash.new
                @plan_rebuilder = plan_rebuilder
                @current_plan = Roby::Plan.new
                @displays = []
                layout.add_widget(list)

                connect(list, SIGNAL('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'),
                           self, SLOT('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'))
            end

            def add_display(display)
                @displays << display
            end

            def add_missing_cycles(count)
                item = Qt::ListWidgetItem.new(list)
                item.setBackground(Qt::Brush.new(Qt::Color::fromHsv(33, 111, 255)))
                item.flags = Qt::NoItemFlags
                item.text = "[#{count} cycles missing]"
            end

            def append_to_history(snapshot)
                cycle = snapshot.stats[:cycle_index]
                time = Time.at(*snapshot.stats[:start]) + snapshot.stats[:real_start]

                item = Qt::ListWidgetItem.new(list)
                item.text = "@#{cycle} - #{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}"
                item.setData(Qt::UserRole, Qt::Variant.new(cycle))
                history[cycle] = [time, snapshot, item]
            end

            slots 'currentItemChanged(QListWidgetItem*,QListWidgetItem*)'
            def currentItemChanged(new_item, previous_item)
                data = new_item.data(Qt::UserRole).toInt
                @current_plan.owners.clear
                Distributed.disable_ownership do
                    @current_plan.clear
                    history[data][1].plan.copy_to(@current_plan)
                end
                displays.each(&:update)
            end

            attr_reader :last_cycle
            attr_reader :last_cycle_snapshotted

            def push_data(data)
                needs_snapshot = plan_rebuilder.push_data(data)
                cycle = plan_rebuilder.stats[:cycle_index]
                if last_cycle && (cycle != last_cycle + 1)
                    add_missing_cycles(cycle - last_cycle - 1)
                end
                if needs_snapshot || @last_cycle_snapshotted
                    append_to_history(plan_rebuilder.history.last)
                    @last_cycle_snapshotted = needs_snapshot
                end
                @last_cycle = cycle
            end

            def analyze(stream, display_progress = true)
                stream.rewind
                start_time, end_time = stream.range

                dialog = Qt::ProgressDialog.new("Analyzing log file", "Quit", 0, (end_time - start_time))
                dialog.setWindowModality(Qt::WindowModal)
                dialog.show

                @last_cycle = nil
                while !stream.eof?
                    data = stream.read
                    push_data(data)
                    dialog.setValue(plan_rebuilder.time - start_time)
                    if dialog.wasCanceled
                        Kernel.raise Interrupt
                    end
                end
                dialog.dispose
            end
        end

	module TaskDisplayConfiguration
            # A set of prefixes that should be removed from the task names
	    attribute(:removed_prefixes) { Set.new }

            # Any task whose label matches one regular expression in this set is
            # not displayed
            attribute(:hidden_labels) { Array.new }

	    # Compute the prefixes to remove from in filter_prefixes:
	    # enable only the ones that are flagged, and sort them by
	    # prefix length
	    def update_prefixes_removal
		@prefixes_removal = removed_prefixes.to_a.
                    sort_by { |p| p.length }.
		    reverse
	    end

            def filtered_out_label?(label)
                (!hidden_labels.empty? && hidden_labels.any? { |match| label.include?(match) })
            end

	    def filter_prefixes(string)
		# @prefixes_removal is computed in RelationsCanvas#update
		for prefix in @prefixes_removal
		    string = string.gsub(prefix, '')
		end
                if string =~ /^::/
                    string = string[2..-1]
                end
		string
	    end

	    # If true, show the ownership in the task descriptions
	    attribute(:show_ownership) { true }
	    # If true, show the arguments in the task descriptions
	    attribute(:show_arguments) { false }
	end
    end
end


