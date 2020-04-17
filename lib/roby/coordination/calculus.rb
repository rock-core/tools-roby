# frozen_string_literal: true

module Roby
    module Tools
        module Calculus
            module Build
                def self.unary_op(name)
                    define_method(name) do
                        Unary.new(name, self)
                    end
                end

                def self.binary_op(name)
                    define_method(name) do |arg|
                        Binary.new(name, self, arg)
                    end
                end

                unary_op :-@
                unary_op :+@
                binary_op :+
                binary_op :-
                binary_op :*
                binary_op :/
                binary_op :**
            end
            Unary = Struct.new :op, :val do
                def evaluate(variables)
                    val.evaluate(variables).send(op)
                end
                include Build
            end
            Binary = Struct.new :op, :left, :right do
                def evaluate(variables)
                    left.evaluate(variables).send(op, right.evaluate(variables))
                end
                include Build
            end
        end
    end
end
