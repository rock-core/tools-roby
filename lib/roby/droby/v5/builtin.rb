# frozen_string_literal: true

require "set"

module Roby
    module DRoby
        module V5
            module Builtins
                module ClassDumper
                    def droby_dump(peer)
                        # Ancestry marshalling stops at the last class that has
                        # ClassDumper built-in. This class is expected to be
                        # resolvable by the remote object manager
                        super_c = superclass
                        super_c = if super_c.kind_of?(ClassDumper)
                                      peer.dump(super_c)
                                  end

                        DRobyClass.new(
                            name,
                            peer.known_siblings_for(self),
                            super_c)
                    end
                end

                module ExceptionDumper
                    def droby_dump(peer, droby_class: DRoby)
                        formatted = Roby.format_exception(self)
                        droby = droby_class.new(
                            peer.dump(self.class),
                            formatted,
                            message)
                        droby.set_backtrace backtrace
                        droby
                    end

                    class DRoby < Exception # rubocop:disable Lint/InheritException
                        attr_reader :exception_class, :formatted_message

                        def initialize(exception_class, formatted_message, message = nil)
                            @exception_class, @formatted_message =
                                exception_class, formatted_message
                            super(message)
                        end

                        def pretty_print(pp)
                            pp.seplist(formatted_message) do |line|
                                pp.text line
                            end
                        end

                        def proxy(peer)
                            exception = self.class.new(peer.local_object(exception_class), formatted_message, message)
                            exception.set_backtrace backtrace
                            exception
                        end

                        def kind_of?(obj)
                            if exception_class.kind_of?(Class)
                                exception_class <= obj
                            else
                                super
                            end
                        end
                    end
                end

                module ArrayDumper
                    def droby_dump(peer)
                        map do |obj|
                            peer.dump(obj)
                        end
                    end

                    def proxy(peer) # :nodoc:
                        map do |element|
                            peer.local_object(element)
                        end
                    end
                end

                module HashDumper
                    def droby_dump(peer)
                        result = {}
                        each do |k, v|
                            result[peer.dump(k)] = peer.dump(v)
                        end
                        result
                    end

                    def proxy(peer) # :nodoc:
                        result = {}
                        each do |k, v|
                            result[peer.local_object(k)] = peer.local_object(v)
                        end
                        result
                    end
                end

                module SetDumper
                    def droby_dump(peer)
                        result = Set.new
                        each do |v|
                            result << peer.dump(v)
                        end
                        result
                    end

                    def proxy(peer) # :nodoc:
                        result = Set.new
                        each do |element|
                            result << peer.local_object(element)
                        end
                        result
                    end
                end
            end
        end
    end
end
