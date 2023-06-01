# frozen_string_literal: true

require "minitest"

module Roby
    module Test
        # Minitest reporter aware of how exceptions should be displayed in Roby
        class MinitestReporter < Minitest::SummaryReporter
            # Overload of Minitest::SummaryReporter#aggregated_results
            def aggregated_results(io)
                filtered_results = results.find_all { |result| show_result?(result) }
                filtered_results.each_with_index do |result, i|
                    io.puts format("\n%<i>3d) %<result>s",
                                   i: i + 1, result: result_to_s(result))
                end

                io.puts
                io
            end

            # Whether the reporter should show this result
            #
            # @param [Minitest::Result] result
            def show_result?(result)
                skip = options[:skip]
                (!result.skipped? || options[:verbose]) &&
                    (!skip || !skip.include?(result.result_code))
            end

            # Generate the string to display for a given test result
            #
            # @param [Minitest::Result] result
            # @return [String]
            def result_to_s(result)
                result.failures.map do |f|
                    message = failure_message(f)

                    "#{f.result_label}:\n#{result.location}:\n#{message}"
                end.join("\n\n")
            end

            # Generate a message for a test failure
            #
            # @param [Minitest::Assertion] failure
            # @return [String]
            def failure_message(failure)
                return failure.message unless roby_exception?(failure)

                io = StringIO.new
                Roby.display_exception(io, failure.error)
                io.string
            end

            # Whether this failure encapsulate a Roby exception or a normal one
            #
            # @param [Minitest::Assertion] f
            def roby_exception?(failure)
                failure.respond_to?(:error) && failure.error.kind_of?(ExceptionBase)
            end
        end
    end
end
