require 'roby/test/self'
require 'roby/schedulers/temporal'

class TC_TemporalConstraints < Minitest::Test
    TemporalConstraints = EventStructure::TemporalConstraints

    def temporal_constraints_graph
        @temporal_constraints_graph ||= plan.event_relation_graph_for(TemporalConstraints)
    end

    def test_empty_constraints
        t1, t2 = prepare_plan add: 2, model: Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event

        set = EventStructure::TemporalConstraintSet.new
        e1.add_forward_temporal_constraint(e2, set)

        assert !e1.has_temporal_constraints?
        assert e2.has_temporal_constraints?

        e1.emit
        assert !e2.find_failed_temporal_constraint(Time.now)
    end

    def test_occurence_constraint_minmax
        plan.add(e1 = Roby::EventGenerator.new(true))
        plan.add(e2 = Roby::EventGenerator.new(true))
        e1.add_occurence_constraint(e2, 1, 2)
        assert !e2.meets_temporal_constraints?(Time.now)
        with_log_level(Roby, Logger::FATAL) do
            assert_raises(EventStructure::OccurenceConstraintViolation) { e2.emit }
        end

        plan.add(e1 = Roby::EventGenerator.new(true))
        plan.add(e2 = Roby::EventGenerator.new(true))
        e1.add_occurence_constraint(e2, 1, 2)
        e1.emit
        assert e2.meets_temporal_constraints?(Time.now)
        e2.emit

        plan.add(e1 = Roby::EventGenerator.new(true))
        plan.add(e2 = Roby::EventGenerator.new(true))
        e1.add_occurence_constraint(e2, 1, 2)
        e1.emit
        assert e2.meets_temporal_constraints?(Time.now)
        e2.emit
        e1.emit
        e1.emit
        assert !e2.meets_temporal_constraints?(Time.now)
        with_log_level(Roby, Logger::FATAL) do
            assert_raises(EventStructure::OccurenceConstraintViolation) { e2.emit }
        end
    end

    def test_occurence_constraint_minmax_recurrent
        plan.add(e1 = Roby::EventGenerator.new(true))
        plan.add(e2 = Roby::EventGenerator.new(true))
        e1.add_occurence_constraint(e2, 1, 2, true)
        assert !e2.meets_temporal_constraints?(Time.now)
        with_log_level(Roby, Logger::FATAL) do
            assert_raises(EventStructure::OccurenceConstraintViolation) { e2.emit }
        end

        plan.add(e1 = Roby::EventGenerator.new(true))
        plan.add(e2 = Roby::EventGenerator.new(true))
        e1.add_occurence_constraint(e2, 1, 2, true)
        e1.emit
        assert e2.meets_temporal_constraints?(Time.now)
        e2.emit
        # Counts are reset
        assert !e2.meets_temporal_constraints?(Time.now)
        with_log_level(Roby, Logger::FATAL) do
            assert_raises(EventStructure::OccurenceConstraintViolation) { e2.emit }
        end

        plan.add(e1 = Roby::EventGenerator.new(true))
        plan.add(e2 = Roby::EventGenerator.new(true))
        e1.add_occurence_constraint(e2, 1, 2, true)
        e1.emit
        assert e2.meets_temporal_constraints?(Time.now)
        e1.emit
        assert e2.meets_temporal_constraints?(Time.now)
        e1.emit
        assert !e2.meets_temporal_constraints?(Time.now)
        with_log_level(Roby, Logger::FATAL) do
            assert_raises(EventStructure::OccurenceConstraintViolation) { e2.emit }
        end
    end

    def test_has_temporal_constraints
        t1, t2 = prepare_plan add: 2
        e1 = t1.start_event
        e2 = t2.start_event

        assert !e1.has_temporal_constraints?
        assert !e2.has_temporal_constraints?

        e1.add_temporal_constraint(e2, 5, 10)
        assert !e1.has_temporal_constraints?
        assert e2.has_temporal_constraints?

        e1.add_temporal_constraint(e2, -5, 10)
        assert e1.has_temporal_constraints?
        assert e2.has_temporal_constraints?
    end

    def test_disjoint_intervals_add
        set = EventStructure::DisjointIntervalSet.new
        set.add(0, 10)
        set.add(11, 12)
        assert_equal [[0, 10], [11, 12]], set.intervals

        set.add(-5, -3)
        assert_equal [[-5, -3], [0, 10], [11, 12]], set.intervals

        set.add(-2, -1)
        assert_equal [[-5, -3], [-2, -1], [0, 10], [11, 12]], set.intervals

        set.add(13, 14)
        set.add(-1.5, 11.5)
        assert_equal [[-5, -3], [-2, 12], [13, 14]], set.intervals
    end

    def test_empty_disjoint_intervals_included_p
        set = EventStructure::DisjointIntervalSet.new
        assert !set.include?(-6)
        assert !set.include?(-4)
        assert !set.include?(-2.5)
        assert !set.include?(-0.5)
        assert !set.include?(1)
        assert !set.include?(13)
    end

    def test_disjoint_intervals_included_p
        set = EventStructure::DisjointIntervalSet.new
        set.add(0, 10)
        set.add(11, 12)
        set.add(-5, -3)
        set.add(-2, -1)
        assert_equal [[-5, -3], [-2, -1], [0, 10], [11, 12]], set.intervals

        assert !set.include?(-6)
        assert set.include?(-4)
        assert !set.include?(-2.5)
        assert !set.include?(-0.5)
        assert set.include?(1)
        assert !set.include?(13)
    end

    def test_add_temporal_constraints
        t1, t2 = prepare_plan add: 2
        e1 = t1.start_event
        e2 = t2.start_event

        e1.add_temporal_constraint(e2, -5, 10)

        assert_raises(ArgumentError) { e1.add_temporal_constraint(e2, 5, 0) }

        assert temporal_constraints_graph.has_edge?(e1, e2)
        assert_equal [[-5, 10]], e1[e2, TemporalConstraints].intervals
        assert temporal_constraints_graph.has_edge?(e2, e1)
        assert_equal [[-10, 5]],  e2[e1, TemporalConstraints].intervals

        t1.start_event.add_temporal_constraint(t2.start_event, 12, 13)
        assert_equal [[-5, 10], [12, 13]], e1[e2, TemporalConstraints].intervals
        assert_equal [[-10, 5]],  e2[e1, TemporalConstraints].intervals

        t1.start_event.add_temporal_constraint(t2.start_event, -7, -6)
        assert_equal [[-5, 10], [12, 13]], e1[e2, TemporalConstraints].intervals
        assert_equal [[-10, 5], [6, 7]],  e2[e1, TemporalConstraints].intervals
    end

    def test_missed_deadline
        t1, t2 = prepare_plan add: 2, model: Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event

        e1.add_temporal_constraint(e2, 0, 10)
        
        FlexMock.use(Time) do |time|
            current_time = Time.now
            time.should_receive(:now).and_return { current_time }

            e1.emit
            assert_equal [], temporal_constraints_graph.check_structure(plan)
            current_time += 11
            errors = temporal_constraints_graph.check_structure(plan)
            assert_equal 1, errors.size

            err = errors.first
            assert_kind_of EventStructure::MissedDeadlineError, err
            assert_equal e1.last, err.constraining_event
        end
    end

    def test_deadline_updates_on_emission
        t1, t2 = prepare_plan add: 2, model: Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event

        e1.add_temporal_constraint(e2, 0, 10)
        
        FlexMock.use(Time) do |time|
            current_time = Time.now
            time.should_receive(:now).and_return { current_time }

            e1.emit
            assert_equal [], temporal_constraints_graph.check_structure(plan)
            current_time += 2
            assert_equal [], temporal_constraints_graph.check_structure(plan)
            e2.emit
            assert plan.emission_deadlines.deadlines.empty?
            current_time += 10
            assert_equal [], temporal_constraints_graph.check_structure(plan)
        end
    end

    def test_deadlines_consider_history
        t1, t2, t3 = prepare_plan add: 3, model: Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event
        e3 = t3.start_event

        # Add a cross-constraint. What will happen is that the emission of e1
        # followed by the one of e2 could create a constraint on e1 again,
        # depending on when e2 has been emitted
        e1.add_temporal_constraint(e2, -5, 10)
        e1.add_temporal_constraint(e3, -5, 10)
        
        FlexMock.use(Time) do |time|
            current_time = Time.now
            time.should_receive(:now).and_return { current_time }

            e1.emit
            assert_equal [], temporal_constraints_graph.check_structure(plan)
            current_time += 2
            assert_equal [], temporal_constraints_graph.check_structure(plan)
            assert_equal 2, plan.emission_deadlines.size
            e2.emit
            assert_equal 1, plan.emission_deadlines.size
            current_time += 4
            e3.emit
            assert_equal 1, plan.emission_deadlines.size
            current_time += 6

            errors = temporal_constraints_graph.check_structure(plan)
            assert_equal 1, errors.size
            err = errors.first
            # Try formatting it to check that there are no hard errors (does not
            # check the formatting, obviously)
            Roby.format_exception(err)
            assert_kind_of EventStructure::MissedDeadlineError, err
            assert_equal e3.last, err.constraining_event
        end
    end

    def test_temporal_constraint_violation
        t1, t2, t3 = prepare_plan add: 3, model: Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event

        e1.add_temporal_constraint(e2, 0, 10)
        e1.add_temporal_constraint(e2, 15, 20)

        FlexMock.use(Time) do |time|
            current_time = Time.now
            time.should_receive(:now).and_return { current_time }

            e1.emit
            current_time += 12
            with_log_level(Roby, Logger::FATAL) do
                assert_raises(EventStructure::TemporalConstraintViolation) { e2.emit }
            end
        end
    end

    def test_temporal_constraint_when_source_did_not_emit_yet
        e1, e2 = EventGenerator.new(true), EventGenerator.new(true)
        plan.add(e1)
        plan.add(e2)

        e1.add_temporal_constraint(e2, 0, 10)

        FlexMock.use(Time) do |time|
            current_time = Time.now
            time.should_receive(:now).and_return { current_time }

            e2.emit
            current_time += 6
            e1.emit
            current_time += 6
            e2.emit
            current_time += 6
            with_log_level(Roby, Logger::FATAL) do
                assert_raises(EventStructure::TemporalConstraintViolation) { e2.emit }
            end
        end
    end
end

