# frozen_string_literal: true

require "roby/gui/stepping_ui"

module Roby
    module GUI
        # GUI dialog that allows to display plans step-by-step instead of
        # cycle-by-cycle
        class Stepping < Qt::Dialog
            attr_reader :ui

            attr_reader :plan
            attr_reader :logfile
            attr_reader :plan_rebuilder

            # Create a step-by-step replay starting at the beginning of a cycle
            # in the log stream
            #
            # @param main_widget this widget's parent
            # @param [DRoby::RebuiltPlan] plan the plan into which the replay is
            #   done. Most of the time it will be the plan that is being
            #   displayed
            # @param [DRoby::Logfile::Reader] logfile the log file
            # @param [Integer] starting_cycle the ID of the cycle at which to
            #   start stepping
            def initialize(main_widget, plan, logfile, starting_cycle)
                super(main_widget)

                @ui = Ui_Stepping.new
                @ui.setupUi(self)
                Qt::Object.connect(ui.btn_next, SIGNAL("clicked()"), self, SLOT("step_forward()"))

                @main_widget = main_widget
                @plan = plan
                plan.clear
                @plan_rebuilder = DRoby::PlanRebuilder.new(plan: plan)
                @logfile = logfile
                PlanRebuilderWidget.analyze(plan_rebuilder, logfile, until_cycle: starting_cycle - 1)

                @main_widget.redraw

                @current_cycle_data = []

                @current_cycle_position = 0
                @current_cycle_size = 0
                unless logfile.eof?
                    @current_cycle_data = logfile.load_one_cycle
                    @current_cycle_position = 0
                    @current_cycle_size = @current_cycle_data.size / 4
                end
                display_current_position
            end

            def display_current_position
                ui.index.text = @current_cycle_position.to_s
                ui.index_count.text = @current_cycle_size.to_s
                ui.cycle.text = @plan_rebuilder.cycle_index.to_s
                ui.cycle_count.text = @logfile.index.cycle_count.to_s
                ui.time.text = @plan_rebuilder.current_time.to_hms
            end

            def step_forward
                plan_rebuilder.clear_integrated
                @plan_rebuilder.plan.clear_integrated
                while !logfile.eof?
                    while @current_cycle_data.empty?
                        @current_cycle_data = logfile.load_one_cycle
                        @current_cycle_position = 0
                        @current_cycle_size = @current_cycle_data.size / 4
                    end

                    while !@current_cycle_data.empty?
                        data = []
                        4.times do
                            data << @current_cycle_data.shift
                        end
                        @current_cycle_position += 1

                        plan_rebuilder.process_one_cycle(data)
                        if plan_rebuilder.has_event_propagation_updates? ||
                           plan_rebuilder.has_structure_updates?
                            plan_rebuilder.clear_changes
                            return
                        end
                    end
                end
            ensure
                display_current_position
                @main_widget.redraw
            end
            slots "step_forward()"
        end
    end
end
