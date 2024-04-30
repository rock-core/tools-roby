# frozen_string_literal: true

module Roby
    module Test
        class << self
            def sampling(engine, duration, period, *fields)
                Test.info "starting sampling #{fields.join(', ')} every #{period}s for #{duration}s"

                samples = []
                fields.map!(&:to_sym)
                if fields.include?(:dt)
                    raise ArgumentError, "dt is reserved by #sampling"
                end

                if (compute_time = !fields.include?(:t))
                    fields << :t
                end
                fields << :dt

                sample_type = Struct.new(*fields)

                start = Time.now
                Roby.condition_variable(true) do |cv, mt|
                    first_sample = nil
                    mt.synchronize do
                        timeout = false
                        id = engine.every(period) do
                            result = yield
                            if result
                                if compute_time
                                    result << engine.cycle_start
                                end
                                new_sample = sample_type.new(*result)

                                unless samples.empty?
                                    new_sample.dt = new_sample.t - samples.last.t
                                end
                                samples << new_sample

                                if samples.last.t - samples.first.t > duration
                                    mt.synchronize do
                                        timeout = true
                                        cv.broadcast
                                    end
                                end
                            end
                        end

                        until timeout
                            cv.wait(mt)
                        end
                        engine.remove_periodic_handler(id)
                    end
                end

                samples
            end

            Stat = Struct.new :total, :count, :mean, :stddev, :min, :max # rubocop:disable Lint/StructNewOverride

            # Computes mean and standard deviation about the samples in
            # +samples+ +spec+ describes what to compute:
            # * if nothing is specified, we compute the statistics on
            #     v(i - 1) - v(i)
            # * if spec['fieldname'] is 'rate', we compute the statistics on
            #     (v(i - 1) - v(i)) / (t(i - 1) / t(i))
            # * if spec['fieldname'] is 'absolute', we compute the
            #   statistics on
            #     v(i)
            # * if spec['fieldname'] is 'absolute_rate', we compute the
            #   statistics on
            #     v(i) / (t(i - 1) / t(i))
            #
            # The returned value is a struct with the same fields than the
            # samples. Each element is a Stats object
            def stats(samples, spec)
                return if samples.empty?

                type = samples.first.class
                spec = spec.inject({}) do |h, (k, v)|
                    spec[k.to_sym] = v.to_sym
                    spec
                end
                spec[:t]  = :exclude
                spec[:dt] = :absolute

                # Initialize the result value
                fields = type.members
                             .find_all { |n| spec[n.to_sym] != :exclude }
                             .map(&:to_sym)
                result = Struct.new(*fields).new
                fields.each do |name|
                    result[name] = Stat.new(0, 0, 0, 0, nil, nil)
                end

                # Compute the deltas if the mode is not absolute
                last_sample = nil
                samples = samples.map do |original_sample|
                    sample = original_sample.dup
                    fields.each do |name|
                        next unless (value = sample[name])

                        unless spec[name] == :absolute || spec[name] == :absolute_rate
                            if last_sample && last_sample[name]
                                sample[name] -= last_sample[name]
                            else
                                sample[name] = nil
                                next
                            end
                        end
                    end
                    last_sample = original_sample
                    sample
                end

                # Compute the rates if needed
                samples = samples.map do |sample|
                    fields.each do |name|
                        next unless (value = sample[name])

                        if spec[name] == :rate || spec[name] == :absolute_rate
                            if sample.dt
                                sample[name] = value / sample.dt
                            else
                                sample[name] = nil
                                next
                            end
                        end
                    end
                    sample
                end

                samples.each do |sample|
                    fields.each do |name|
                        next unless (value = sample[name])

                        if !result[name].max || value > result[name].max
                            result[name].max = value
                        end
                        if !result[name].min || value < result[name].min
                            result[name].min = value
                        end

                        result[name].total += value
                        result[name].count += 1
                    end
                    last_sample = sample
                end

                result.each do |r|
                    r.mean = Float(r.total) / r.count
                end

                samples.each do |sample|
                    fields.each do |name|
                        next unless (value = sample[name])

                        result[name].stddev += (value - result[name].mean)**2
                    end
                end

                result.each do |r|
                    r.stddev = Math.sqrt(r.stddev / r.count)
                end

                result
            end
        end
    end
end
