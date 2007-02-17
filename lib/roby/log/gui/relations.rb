require 'Qt4'
require 'roby'
require 'roby/log/relations'
require 'roby/log/gui/relations_ui'

module Ui
    class RelationConfigModel < Qt::AbstractItemModel
	COL_NAME    = 0
	COL_COLOR   = 1

	COLORS = %w{'black' #800000 #008000 #000080 #C05800 #6633FF #CDBE70 #CD8162 #A2B5CD}
	attr_reader :current_color
	# returns the next color in COLORS, cycles if at the end of the array
	def allocate_color
	    @current_color = (current_color + 1) % COLORS.size
	    COLORS[current_color]
	end

	CATEGORIES = ['Task structure', 'Event structure']

	attr_reader :relations
	attr_reader :display
	def initialize(display)
	    super()

	    Roby.load_all_relations
	    @current_color = 0
	    @display   = display
	    @relations = []

	    relations[1] = Roby::EventStructure.enum_for(:each_relation).map { |rel| [rel, allocate_color] }
	    relations[0] = Roby::TaskStructure.enum_for(:each_relation).map { |rel| [rel, allocate_color] }
	end

	def index(row, column, parent)
	    if parent.valid? && parent.internal_id == -1
		create_index(row, column, parent.row)
	    elsif row < relations.size
		create_index(row, column, -1)
	    else
		Qt::ModelIndex.new
	    end
	end
	def parent(index)
	    category = index.internal_id
	    if !index.valid? || category == -1 then Qt::ModelIndex.new
	    else create_index(category, 0, -1) end
	end
	def columnCount(parent); 2 end
	def hasChildren(parent); !parent.valid? || parent.internal_id == -1 end
	def rowCount(parent)
	    if !parent.valid? then relations.size
	    else relations[parent.row].size end
	end
	def headerData(section, orientation, role)
	    return Qt::Variant.new unless role == Qt::DisplayRole && orientation == Qt::Horizontal
	    value = if section == 0 then "Relation"
		    else "Color" end
	    Qt::Variant.new(value)
	end
	def data(index, role)
	    return Qt::Variant.new unless index.valid?

	    category = index.internal_id
	    value = if category == -1
			if index.column == COL_NAME && role == Qt::DisplayRole
			    CATEGORIES[index.row]
			end
		    else
			relation, color = relations[category][index.row]
			if index.column == COL_NAME && role == Qt::CheckStateRole
			    if display.relation_enabled?(relation) then Qt::Checked.to_i
			    else Qt::Unchecked.to_i
			    end
			elsif index.column == COL_NAME && role == Qt::DisplayRole
			    relation.name.gsub(/.*Structure::/, '')
			elsif index.column == COL_COLOR && role == Qt::DisplayRole
			    color
			end
		    end

	    if value then Qt::Variant.new(value)
	    else Qt::Variant.new
	    end
	end
	def setData(index, value, role)
	    category = index.internal_id
	    relation, color = relations[category][index.row]
	    if role == Qt::CheckStateRole
		if value.to_i == Qt::Checked.to_i
		    display.enabled_relations << relation
		else
		    display.enabled_relations.delete relation
		end
	    else
		relations[category][index.row][1] = value.to_string
	    end
	    emit dataChanged(index, index)
	end
	def flags(index)
	    if !index.valid? || index.internal_id == -1 then Qt::ItemIsEnabled 
	    else 
		flags = Qt::ItemIsSelectable | Qt::ItemIsUserCheckable | Qt::ItemIsEnabled
		if index.column == 1
		    flags = Qt::ItemIsEditable | flags
		end
		flags
	    end
	end
    end
    class RelationDelegate < Qt::ItemDelegate
	MAX_WIDTH = 50
	def createEditor(parent, option, index)
	    color = index.model.data(index, Qt::DisplayRole).to_string
	    new_color = Qt::ColorDialog.get_color(Qt::Color.new(color))
	    index.model.setData(index, Qt::Variant.new(new_color.name), Qt::DisplayRole)

	    nil
	end
	def paint(painter, option, index)
	    if index.column == 1 && index.internal_id >= 0
		color = index.model.data(index, Qt::DisplayRole).to_string
		rect = option.rect
		rect.adjust(1, 1, -1, -1)
		if rect.width > MAX_WIDTH
		    rect.width = MAX_WIDTH
		end
		painter.fill_rect rect, Qt::Brush.new(Qt::Color.new(color))
	    else
		super
	    end
	end
    end

    class RelationsConfig
	attr_reader :current_color
	attr_reader :relation_color
	attr_reader :relation_item
	def setupUi(widget)
	    super(widget)

	    display   = Roby::Log::Display::Relations.new
	    @model    = RelationConfigModel.new(display)
	    @delegate = RelationDelegate.new
	    lst_relations.set_item_delegate @delegate
	    lst_relations.header.resize_mode = Qt::HeaderView::Stretch
	    lst_relations.model = @model

	    display
	end
    end
end

if $0 == __FILE__
    a = Qt::Application.new(ARGV)
    u = Ui::RelationsConfig.new
    w = Qt::Widget.new
    u.setupUi(w)
    w.show
    a.exec
end

