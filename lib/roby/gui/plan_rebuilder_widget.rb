require 'roby/gui/qt4_toMSecsSinceEpoch'
require 'roby/droby/plan_rebuilder'
require 'roby/gui/stepping'

module Roby
    module GUI
        # This widget displays information about the event history in a list,
        # allowing to switch between the "important events" in this history
        class PlanRebuilderWidget < Qt::Widget
            # The list used to display all the cycles in the history
            attr_reader :list
            # The history, as a mapping from the cycle index to a (time,
            # snapshot, list_item) triple
            attr_reader :history
            # The PlanRebuilder object we use to process the log data
            attr_reader :plan_rebuilder
            # The current plan managed by the widget
            attr_reader :current_plan
            # The underlying log file
            # @return [DRoby::Logfile::Reader]
            attr_reader :logfile
            # The last processed cycle
            # @return [Integer]
            attr_reader :last_cycle

            # Signal emitted when an informational message is meant to be
            # displayed
            signals 'info(QString)'
            # Signal emitted when a warning message is meant to be displayed
            signals 'warn(QString)'
            # Signal emitted when the currently displayed cycle changed, i.e.
            # when displays are supposed to be updated
            signals 'appliedSnapshot(QDateTime)'

            def initialize(parent, plan_rebuilder)
                super(parent)
                @list    = Qt::ListWidget.new(self)
                @layout  = Qt::VBoxLayout.new(self)

                def list.mouseReleaseEvent(event)
                    if event.button == Qt::RightButton
                        event.accept

                        menu = Qt::Menu.new
                        inspect_cycle = menu.add_action("Step-by-step from there")
                        if action = menu.exec(event.globalPos)
                            cycle_index = currentItem.data(Qt::UserRole).toInt

                            rebuilder_widget = self.parentWidget
                            stepping = Stepping.new(
                                rebuilder_widget,
                                rebuilder_widget.current_plan,
                                rebuilder_widget.logfile.dup,
                                cycle_index)
                            stepping.exec
                        end
                    end
                end

                @layout.add_widget(@btn_create_display)
                @history = Hash.new
                @logfile = nil # set by #open
                @plan_rebuilder = plan_rebuilder
                @current_plan = DRoby::RebuiltPlan.new
                @layout.add_widget(list)

                Qt::Object.connect(list, SIGNAL('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'),
                           self, SLOT('currentItemChanged(QListWidgetItem*,QListWidgetItem*)'))
            end


            # Info about all tasks known within the stored history
            #
            # @return [(Set<Roby::Task>,Hash<Roby::Task,Roby::Task>)] returns
            #   the set of all tasks stored in the history, as well as a mapping
            #   from job placeholder tasks to the corresponding job task
            def tasks_info
                all_tasks = Set.new
                all_job_info = Hash.new
                history.each_key do |cycle_index|
                    tasks, job_info = tasks_info_of_snapshot(cycle_index)
                    all_tasks.merge(tasks)
                    all_job_info.merge!(job_info)
                end
                return all_tasks, all_job_info
            end

            # Returns the set of tasks that are present in the given snapshot
            #
            # @return [Set<Roby::Task>]
            def tasks_info_of_snapshot(cycle)
                _, snapshot, * = history[cycle]
                tasks = snapshot.plan.tasks.to_set
                job_info = Hash.new
                tasks.each do |t|
                    if t.kind_of?(Roby::Interface::Job)
                        planned_by_graph = snapshot.plan.task_relation_graph_for(Roby::TaskStructure::PlannedBy)
                        placeholder_task = planned_by_graph.enum_for(:each_out_neighbour, t).first
                        if placeholder_task
                            job_info[placeholder_task] = t
                        end
                    end
                end
                return tasks, job_info
            end

            # Returns the job information for the given task in the given cycle
            def job_placeholder_of(task, cycle)
                if task.kind_of?(Roby::Interface::Job)
                    _, snapshot, * = history[cycle]
                    task.
                        enum_parent_objects(snapshot.relations[Roby::TaskStructure::PlannedBy]).
                        first
                end
            end

            def add_missing_cycles(count)
                item = Qt::ListWidgetItem.new(list)
                item.setBackground(Qt::Brush.new(Qt::Color::fromHsv(33, 111, 255)))
                item.flags = Qt::NoItemFlags
                item.text = "[#{count} cycles missing]"
            end

            Snapshot = Struct.new :stats, :plan

            def append_to_history
                snapshot = Snapshot.new plan_rebuilder.stats.dup,
                    DRoby::RebuiltPlan.new
                snapshot.plan.merge(plan_rebuilder.plan)
                if @last_snapshot
                    snapshot.plan.dedupe(@last_snapshot.plan)
                end
                @last_snapshot = snapshot

                cycle = snapshot.stats[:cycle_index]
                time = Time.at(*snapshot.stats[:start]) + snapshot.stats[:actual_start]

                item = Qt::ListWidgetItem.new(list)
                item.text = "@#{cycle} - #{Roby.format_time(time)}"
                item.setData(Qt::UserRole, Qt::Variant.new(cycle))
                history[cycle] = [time, snapshot, item]
                emit addedSnapshot(cycle)
            end

            signals 'addedSnapshot(int)'

            slots 'currentItemChanged(QListWidgetItem*,QListWidgetItem*)'
            def currentItemChanged(new_item, previous_item)
                data = new_item.data(Qt::UserRole).toInt
                apply(history[data][1])
            end

            def apply(snapshot)
                @display_time = Time.at(*snapshot.stats[:start]) + snapshot.stats[:end]
                @current_plan.clear
                @current_plan.merge(snapshot.plan)
                emit appliedSnapshot(Qt::DateTime.new(@display_time))
            end

            def seek(time)
                # Convert from QDateTime to allow seek() to be a slot
                if time.kind_of?(Qt::DateTime)
                    time = Time.at(Float(time.toMSecsSinceEpoch) / 1000)
                end

                result = nil
                history.each_value do |cycle_time, snapshot, item|
                    if cycle_time < time
                        if !result || result[0] < cycle_time
                            result = [cycle_time, snapshot]
                        end
                    end
                end
                if result
                    apply(result[1])
                end
            end
            slots 'seek(QDateTime)'

            def push_cycle(snapshot: true)
                cycle = plan_rebuilder.stats[:cycle_index]
                if last_cycle && (cycle != last_cycle + 1)
                    add_missing_cycles(cycle - last_cycle - 1)
                end
                needs_snapshot =
                    (plan_rebuilder.has_structure_updates? ||
                     plan_rebuilder.has_event_propagation_updates?)
                if snapshot && needs_snapshot
                    append_to_history
                end
                @last_cycle = cycle
                Time.at(*plan_rebuilder.stats[:start]) + plan_rebuilder.stats[:actual_start]
            end
            signals 'liveUpdate(QDateTime)'

            def redraw(time = plan_rebuilder.current_time)
                emit appliedSnapshot(Qt::DateTime.new(time))
            end

            # Opens +filename+ and reads the data from there
            def open(filename)
                @logfile = DRoby::Logfile::Reader.open(filename)
                self.window_title = "roby-display: #{filename}"
                emit sourceChanged
                analyze
                if !history.empty?
                    apply(history[history.keys.sort.first][1])
                end
            end

            signals 'sourceChanged()'

            def self.analyze(plan_rebuilder, logfile, until_cycle: nil)
                start_time, end_time = logfile.index.range

                start = Time.now
                puts "log file is #{(end_time - start_time).ceil}s long"
                dialog = Qt::ProgressDialog.new("Analyzing log file", "Quit", 0, (end_time - start_time))
                dialog.setWindowModality(Qt::WindowModal)
                dialog.show

                while !logfile.eof? && (!until_cycle || !plan_rebuilder.cycle_index || plan_rebuilder.cycle_index < until_cycle)
                    data = logfile.load_one_cycle
                    plan_rebuilder.process_one_cycle(data)
                    if block_given?
                        needs_snapshot =
                            (plan_rebuilder.has_structure_updates? ||
                             plan_rebuilder.has_event_propagation_updates?)
                        yield(needs_snapshot, data) 
                    end
                    plan_rebuilder.clear_integrated
                    dialog.setValue(plan_rebuilder.cycle_start_time - start_time)
                    if dialog.wasCanceled
                        Kernel.raise Interrupt
                    end
                end
                dialog.dispose
                puts "analyzed log file in %.2fs" % [Time.now - start]
            end

            def analyze(until_cycle: nil)
                PlanRebuilderWidget.analyze(plan_rebuilder, logfile, until_cycle: until_cycle) do
                    push_cycle
                end
            end

            # Called when the connection to the log server failed, either
            # because it has been closed or because creating the connection
            # failed
            def connection_failed(e, client, options)
                @connection_error = e
                emit warn("connection failed: #{e.message}")
                if @reconnection_timer
                    return
                end

                @reconnection_timer = Qt::Timer.new(self)
                @connect_client  = client.dup
                @connect_options = options.dup
                @reconnection_timer.connect(SIGNAL('timeout()')) do
                    puts "trying to reconnect to #{@connect_client} #{@connect_options}"
                    if connect(@connect_client, @connect_options)
                        emit info("Connected")
                        @reconnection_timer.stop
                        @reconnection_timer.dispose
                        @reconnection_timer = nil
                    end
                end
                @reconnection_timer.start(1000)
            end

            DEFAULT_REMOTE_POLL_PERIOD = 0.05

            # Displays the data incoming from +client+
            #
            # +client+ is assumed to be a {DRoby::Logfile::Client} instance
            #
            # +update_period+ is, in seconds, the period at which the
            # display will check whether there is new data on the port.
            def connect(client, options = Hash.new)
                options = Kernel.validate_options options,
                    port: DRoby::Logfile::Server::DEFAULT_PORT,
                    update_period: DEFAULT_REMOTE_POLL_PERIOD

                if client.respond_to?(:to_str)
                    self.window_title = "roby-display: #{client}"
                    emit sourceChanged

                    begin
                        hostname = client
                        client = DRoby::Logfile::Client.new(client, options[:port])
                    rescue Exception => e
                        connection_failed(e, client, options)
                        return false
                    end
                end


                @client = client
                client.add_listener do |data|
                    plan_rebuilder.clear_integrated
                    plan_rebuilder.process_one_cycle(data)
                    time = push_cycle
                    emit liveUpdate(Qt::DateTime.new(time))

                    cycle = plan_rebuilder.cycle_index
                    time = plan_rebuilder.cycle_start_time
                    emit info("@#{cycle} - #{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}")
                end
                @connection_pull = timer = Qt::Timer.new(self)
                timer.connect(SIGNAL('timeout()')) do
                    begin
                        client.read_and_process_pending(max: 0.1)
                    rescue Exception => e
                        disconnect
                        emit warn("Disconnected: #{e.message}")
                        puts e.message
                        puts "  " + e.backtrace.join("\n  ")
                        if hostname
                            connect(hostname, options)
                        end
                    end
                end
                timer.start(Integer(options[:update_period] * 1000))
                return true
            end

            def disconnect
                @client.disconnect
                @connection_pull.stop
                @connection_pull.dispose
                @connection_pull = nil
            end

            def cycle_start_time
                plan_rebuilder.cycle_start_time
            end

            # The start time of the first received cycle
            def start_time
                plan_rebuilder.start_time
            end

            # The end time of the last received cycle
            def current_time
                plan_rebuilder.current_time
            end

            # The time of the currently selected snapshot
            def display_time
                @display_time || start_time
            end
        end
    end
end


