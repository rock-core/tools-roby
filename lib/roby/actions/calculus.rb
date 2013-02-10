module Roby
    module Tools
        module Calculus
            UNARY_OPS = [:-@, :+, :-, :*, :/, :**]
            module Build
                def method_missing(m, *args, &block)
                    if UNARY_OPS.include?(m)
                        if args.size != 0
                            raise ArgumentError, "#{m} expects no arguments, got #{args.size}"
                        end
                        return Unary.new(m, self)
                    elsif BINARY_OPS.include?(m)
                        if args.size != 1
                            raise ArgumentError, "#{m} expects one argument, got #{args.size}"
                        end
                        return Binary.new(m, self, args[0])
                    end
                    super
                end
            end
            Unary  = Struct.new :op, :val do
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

