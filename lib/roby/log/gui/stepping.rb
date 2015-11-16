require 'roby/log/gui/stepping_ui'

module Roby
    module LogReplay
        # GUI dialog that allows to display plans step-by-step instead of
        # cycle-by-cycle
        class Stepping < Qt::Dialog
            attr_reader :ui

            attr_reader :stream
            attr_reader :plan_rebuilder

            def plan
                plan_rebuilder.plan
            end

            def initialize(main_widget, plan, stream, starting_cycle)
                super(main_widget)

                @ui = Ui_Stepping.new
                @ui.setupUi(self)
                Qt::Object.connect(ui.btn_next, SIGNAL("clicked()"), self, SLOT("step_forward()"))

                @main_widget = main_widget
                @plan_rebuilder = PlanRebuilder.new(plan: plan)
                @plan_rebuilder.plan.clear
                @stream = stream
                PlanRebuilderWidget.analyze(plan_rebuilder, stream, starting_cycle - 1)

                plan_rebuilder.clear_integrated
                @plan_rebuilder.plan.clear_integrated
                @main_widget.redraw

                @current_cycle_data = []

                @current_cycle_position = 0
                @current_cycle_size = 0
                if !stream.eof?
                    @current_cycle_data = stream.read
                    @current_cycle_position = 0
                    @current_cycle_size = @current_cycle_data.size / 4
                end
                display_current_position
            end

            def display_current_position
                ui.index.text = @current_cycle_position.to_s
                ui.index_count.text = @current_cycle_size.to_s
                ui.cycle.text = @plan_rebuilder.cycle_index.to_s
                ui.cycle_count.text = @stream.cycle_count.to_s
                ui.time.text = @plan_rebuilder.current_time.to_hms
            end

            def step_forward
                plan_rebuilder.clear_integrated
                @plan_rebuilder.plan.clear_integrated
                while !stream.eof?
                    while @current_cycle_data.empty?
                        @current_cycle_data = stream.read
                        @current_cycle_position = 0
                        @current_cycle_size = @current_cycle_data.size / 4
                    end

                    while !@current_cycle_data.empty?
                        data = []
                        4.times do
                            data << @current_cycle_data.shift
                        end
                        @current_cycle_position += 1

                        plan_rebuilder.process(data)
                        if plan_rebuilder.has_event_propagation_updates?(plan) ||
                            plan_rebuilder.has_structure_updates?(plan)
                            plan_rebuilder.clear_changes
                            return
                        end
                    end
                end
            ensure
                display_current_position
                @main_widget.redraw
            end
            slots 'step_forward()'
        end
    end
end

