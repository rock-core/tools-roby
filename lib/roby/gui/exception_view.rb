module Roby
    module GUI
        class ExceptionRendering < MetaRuby::GUI::ExceptionRendering
            attr_reader :excluded_patterns

            def initialize(*)
                super
                @excluded_patterns = Regexp.new("^$")
            end

            def add_excluded_pattern(rx)
                @excluded_patterns = Regexp.union(excluded_patterns, rx)
            end

            def each_exception_from(e)
                super do |e|
                    yield e
                    if e.respond_to?(:original_exceptions)
                        e.original_exceptions.each do |original_e|
                            each_exception_from(original_e, &Proc.new)
                        end
                    end
                end
            end

            def filter_backtrace(parsed_backtrace, raw_backtrace)
                raw_backtrace = raw_backtrace.
                    find_all { |l| !(excluded_patterns === l) }
                Roby.filter_backtrace(raw_backtrace, force: true)
            end

            def user_file?(file)
                Roby.app.app_file?(file)
            end
        end

        class ExceptionView < MetaRuby::GUI::ExceptionView
            def initialize(*)
                super
                @exception_rendering = ExceptionRendering.new(self.exception_rendering.linker)
            end
        end
    end
end
