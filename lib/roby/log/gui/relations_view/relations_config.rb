require 'roby/log/gui/relations_view/relations_ui'

module Ui
    # Manage relations using a two-level tree structure. The relation
    # categories (tasks and events) have a model index of (row, column, nil)
    # while the relations have a model index of (row, column, category), where
    # category is TASK_ROOT_INDEX for task relations and EVENT_ROOT_INDEX for
    # event relations
    class RelationConfigModel < Qt::AbstractItemModel
	COL_NAME    = 0
	COL_COLOR   = 1

	TASK_ROOT_INDEX  = 0
	EVENT_ROOT_INDEX = 1
	CATEGORIES = ['Task structure']

	def event_root_index; createIndex(EVENT_ROOT_INDEX, 0, -1) end
	def task_root_index;  createIndex(TASK_ROOT_INDEX, 0, -1) end

	attr_reader :relations
	attr_reader :display
	def initialize(display)
	    super()

	    @current_color = 0
	    @display   = display
	    @relations = []

	    relations[TASK_ROOT_INDEX]  = Roby::LogReplay::RelationsDisplay.all_task_relations

            RelationConfigModel.detect_qtruby_behaviour(createIndex(0, 0, 0))
	end

        QTRUBY_INDEX_USING_POINTERS  = 1
        QTRUBY_INDEX_USING_OBJECTIDS = 2
        def self.detect_qtruby_behaviour(idx)
            if idx.internalPointer == 0
                @@qtruby_behaviour = QTRUBY_INDEX_USING_POINTERS
            elsif idx.internalId == 1
                @@qtruby_behaviour = QTRUBY_INDEX_USING_OBJECTIDS
            end
        end

        def self.category_from_index(idx)
            if @@qtruby_behaviour == QTRUBY_INDEX_USING_POINTERS
                idx.internalPointer
            else
                idx.internalId >> 1
            end
        end

	def index(row, column, parent)
	    if parent.valid? && RelationConfigModel.category_from_index(parent) == -1
		createIndex(row, column, parent.row)
	    elsif row < relations.size
		createIndex(row, column, -1)
	    else
		Qt::ModelIndex.new
	    end
	end

	def parent(index)
	    category = RelationConfigModel.category_from_index(index)
	    if !index.valid? || category == -1 then Qt::ModelIndex.new
	    else createIndex(category, 0, -1) end
	end
	def columnCount(parent); 2 end
	def hasChildren(parent); !parent.valid? || RelationConfigModel.category_from_index(parent) == -1 end
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

	    category = RelationConfigModel.category_from_index(index)
	    value = if category == -1
			if index.column == COL_NAME && role == Qt::DisplayRole
			    CATEGORIES[index.row]
			end
		    else
			relation = relations[category][index.row]
			if index.column == COL_NAME && role == Qt::CheckStateRole
			    if    display.relation_enabled?(relation) then Qt::Checked.to_i
			    elsif display.layout_relation?(relation)  then Qt::PartiallyChecked.to_i
			    else Qt::Unchecked.to_i
			    end
			elsif index.column == COL_NAME && role == Qt::DisplayRole
			    relation.name.gsub(/.*Structure::/, '')
			elsif index.column == COL_COLOR && role == Qt::DisplayRole
			    display.relation_color(relation)
			end
		    end

	    if value then Qt::Variant.new(value)
	    else Qt::Variant.new
	    end
	end
	def setData(index, value, role)
	    category = RelationConfigModel.category_from_index(index)
	    relation = relations[category][index.row]
	    if role == Qt::CheckStateRole
		case value.to_i
		when Qt::Checked.to_i
		    display.enable_relation(relation)
		when Qt::PartiallyChecked.to_i
		    display.layout_relation(relation)
		else
		    display.ignore_relation(relation)
		end
	    else
		display.update_relation_color(relation, value.to_string)
	    end
	    display.update
	    emit dataChanged(index, index)
	end
	def flags(index)
	    if !index.valid? || RelationConfigModel.category_from_index(index) == -1 then Qt::ItemIsEnabled 
	    else 
		flags = Qt::ItemIsSelectable | Qt::ItemIsTristate | Qt::ItemIsEnabled | Qt::ItemIsUserCheckable
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
	    if index.column == 1 && RelationConfigModel.category_from_index(index) >= 0
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

    class LayoutMethodModel < Qt::AbstractListModel
	METHODS    = ["Auto", "dot [rankdir=LR]", "dot [rankdir=TB]", "circo", "neato [overlap=false]", "neato [overlap=false,mode=hier]", "twopi", "fdp"]
	attr_reader :display, :combo
	def initialize(display, combo)
	    super()
	    @display, @combo = display, combo
	end

	def rowCount(parent)
	    return 0 if parent.valid?
	    return METHODS.size
	end
	def data(index, role)
	    return Qt::Variant.new unless role == Qt::DisplayRole && index.valid?
	    Qt::Variant.new(METHODS[index.row])
	end
	def layout_method(index)
	end

	def flags(index)
	    Qt::ItemIsSelectable | Qt::ItemIsEnabled
	end

	def selected
	    index = combo.current_index
	    display.layout_method =
                if index == 0 then nil
                else METHODS[index]
                end
            display.update
	end
	slots 'selected()'
    end

    class RelationsConfig
	attr_reader :current_color
	attr_reader :relation_color
	attr_reader :relation_item
	attr_reader :model
	attr_reader :delegate
        attr_reader :display

        def initialize(widget, display)
            super()
            if !system("dot", "-V")
                raise "the 'dot' tool is unavailable"
            end

            setupUi(widget, display)
        end

	def setupUi(widget, display)
	    super(widget)

            @display = display
	    @model    = RelationConfigModel.new(display)
	    @delegate = RelationDelegate.new
	    relations.set_item_delegate @delegate
	    relations.header.resize_mode = Qt::HeaderView::Stretch
	    relations.model = @model
	    relations.set_expanded model.task_root_index, true
	    relations.set_expanded model.event_root_index, true

            @layout_model = LayoutMethodModel.new(display, layoutMethod)
            Qt::Object.connect(layoutMethod, SIGNAL("currentIndexChanged(int)"), @layout_model, SLOT("selected()"))
	    layoutMethod.model = @layout_model

            showOwnership.checked = display.show_ownership
            showOwnership.connect(SIGNAL('clicked(bool)')) do |state|
                display.show_ownership = state
                display.update
            end
            showFinalized.checked = !display.hide_finalized
            showFinalized.connect(SIGNAL('clicked(bool)')) do |state|
                display.hide_finalized = !state
                display.update
            end
            removedPrefixes.setText(display.removed_prefixes.to_a.join(","))
            removedPrefixes.connect(SIGNAL('textChanged(QString)')) do |removed_prefixes|
                display.removed_prefixes = removed_prefixes.split(',')
                delayed_update
            end
            hiddenLabels.setText(display.hidden_labels.to_a.join(","))
            hiddenLabels.connect(SIGNAL('textChanged(QString)')) do |hidden_labels|
                display.hidden_labels = hidden_labels.split(',')
                delayed_update
            end
            if display.display_policy == :explicit
                displayExplicit.checked = true
            elsif display.display_policy == :emitters
                displayEmitters.checked = true
            elsif display.display_policy == :emitters_and_parents
                displayEmittersAndParents.checked = true
            end

            displayExplicit.connect(SIGNAL('clicked()')) do
                display.display_policy = :explicit
                delayed_update
            end
            displayEmitters.connect(SIGNAL('clicked()')) do
                display.display_policy = :emitters
                delayed_update
            end
            displayEmittersAndParents.connect(SIGNAL('clicked()')) do
                display.display_policy = :emitters_and_parents
                delayed_update
            end

            @delayed_update_timer = Qt::Timer.new(display)
            @delayed_update_timer.setSingleShot(true)
            @delayed_update_timer.connect(SIGNAL('timeout()')) do
                display.update
            end
	end

        # The amount of time we wait before triggering an update on the display.
        # This is meant to avoid unnecessary updates (for instance for
        # configuration parameters in textboxes)
        DELAYED_UPDATE_TIMEOUT = 500

        def delayed_update
            @delayed_update_timer.start(DELAYED_UPDATE_TIMEOUT)
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

