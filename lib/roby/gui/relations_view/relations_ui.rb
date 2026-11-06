=begin
** Form generated from reading ui file 'relations.ui'
**
** Created: qua out 28 14:09:58 2026
**      by: Qt User Interface Compiler version 4.8.7
**
** WARNING! All changes made in this file will be lost when recompiling ui file!
=end

class Ui_RelationsConfig
    attr_reader :verticalLayout
    attr_reader :taskLabelsGroup
    attr_reader :gridLayout
    attr_reader :showOwnership
    attr_reader :lblRemovedPrefixes
    attr_reader :removedPrefixes
    attr_reader :displayOptionsGroup
    attr_reader :gridLayout_2
    attr_reader :displayExplicit
    attr_reader :displayEmitters
    attr_reader :displayEmittersAndParents
    attr_reader :lblHiddenLabels
    attr_reader :hiddenLabels
    attr_reader :showFinalized
    attr_reader :lblLayoutMethod
    attr_reader :layoutMethod
    attr_reader :relations

    def setupUi(relationsConfig)
    if relationsConfig.objectName.nil?
        relationsConfig.objectName = "relationsConfig"
    end
    relationsConfig.resize(428, 668)
    @verticalLayout = Qt::VBoxLayout.new(relationsConfig)
    @verticalLayout.objectName = "verticalLayout"
    @taskLabelsGroup = Qt::GroupBox.new(relationsConfig)
    @taskLabelsGroup.objectName = "taskLabelsGroup"
    @gridLayout = Qt::GridLayout.new(@taskLabelsGroup)
    @gridLayout.objectName = "gridLayout"
    @showOwnership = Qt::CheckBox.new(@taskLabelsGroup)
    @showOwnership.objectName = "showOwnership"
    @showOwnership.checked = true

    @gridLayout.addWidget(@showOwnership, 0, 0, 1, 1)

    @lblRemovedPrefixes = Qt::Label.new(@taskLabelsGroup)
    @lblRemovedPrefixes.objectName = "lblRemovedPrefixes"
    @lblRemovedPrefixes.wordWrap = true

    @gridLayout.addWidget(@lblRemovedPrefixes, 1, 0, 1, 1)

    @removedPrefixes = Qt::LineEdit.new(@taskLabelsGroup)
    @removedPrefixes.objectName = "removedPrefixes"

    @gridLayout.addWidget(@removedPrefixes, 2, 0, 1, 1)


    @verticalLayout.addWidget(@taskLabelsGroup)

    @displayOptionsGroup = Qt::GroupBox.new(relationsConfig)
    @displayOptionsGroup.objectName = "displayOptionsGroup"
    @gridLayout_2 = Qt::GridLayout.new(@displayOptionsGroup)
    @gridLayout_2.objectName = "gridLayout_2"
    @displayExplicit = Qt::RadioButton.new(@displayOptionsGroup)
    @displayExplicit.objectName = "displayExplicit"
    @displayExplicit.checked = true

    @gridLayout_2.addWidget(@displayExplicit, 0, 0, 1, 2)

    @displayEmitters = Qt::RadioButton.new(@displayOptionsGroup)
    @displayEmitters.objectName = "displayEmitters"

    @gridLayout_2.addWidget(@displayEmitters, 1, 0, 1, 2)

    @displayEmittersAndParents = Qt::RadioButton.new(@displayOptionsGroup)
    @displayEmittersAndParents.objectName = "displayEmittersAndParents"

    @gridLayout_2.addWidget(@displayEmittersAndParents, 2, 0, 1, 2)

    @lblHiddenLabels = Qt::Label.new(@displayOptionsGroup)
    @lblHiddenLabels.objectName = "lblHiddenLabels"
    @lblHiddenLabels.wordWrap = true

    @gridLayout_2.addWidget(@lblHiddenLabels, 3, 0, 1, 2)

    @hiddenLabels = Qt::LineEdit.new(@displayOptionsGroup)
    @hiddenLabels.objectName = "hiddenLabels"

    @gridLayout_2.addWidget(@hiddenLabels, 4, 0, 1, 2)

    @showFinalized = Qt::CheckBox.new(@displayOptionsGroup)
    @showFinalized.objectName = "showFinalized"
    @showFinalized.checked = true

    @gridLayout_2.addWidget(@showFinalized, 5, 0, 1, 2)

    @lblLayoutMethod = Qt::Label.new(@displayOptionsGroup)
    @lblLayoutMethod.objectName = "lblLayoutMethod"
    @sizePolicy = Qt::SizePolicy.new(Qt::SizePolicy::Minimum, Qt::SizePolicy::Preferred)
    @sizePolicy.setHorizontalStretch(0)
    @sizePolicy.setVerticalStretch(0)
    @sizePolicy.heightForWidth = @lblLayoutMethod.sizePolicy.hasHeightForWidth
    @lblLayoutMethod.sizePolicy = @sizePolicy

    @gridLayout_2.addWidget(@lblLayoutMethod, 6, 0, 1, 1)

    @layoutMethod = Qt::ComboBox.new(@displayOptionsGroup)
    @layoutMethod.objectName = "layoutMethod"
    @sizePolicy1 = Qt::SizePolicy.new(Qt::SizePolicy::MinimumExpanding, Qt::SizePolicy::Fixed)
    @sizePolicy1.setHorizontalStretch(0)
    @sizePolicy1.setVerticalStretch(0)
    @sizePolicy1.heightForWidth = @layoutMethod.sizePolicy.hasHeightForWidth
    @layoutMethod.sizePolicy = @sizePolicy1

    @gridLayout_2.addWidget(@layoutMethod, 6, 1, 1, 1)


    @verticalLayout.addWidget(@displayOptionsGroup)

    @relations = Qt::TreeView.new(relationsConfig)
    @relations.objectName = "relations"

    @verticalLayout.addWidget(@relations)


    retranslateUi(relationsConfig)

    Qt::MetaObject.connectSlotsByName(relationsConfig)
    end # setupUi

    def setup_ui(relationsConfig)
        setupUi(relationsConfig)
    end

    def retranslateUi(relationsConfig)
    relationsConfig.windowTitle = Qt::Application.translate("RelationsConfig", "RelationsConfig", nil, Qt::Application::UnicodeUTF8)
    @taskLabelsGroup.title = Qt::Application.translate("RelationsConfig", "Task Labels", nil, Qt::Application::UnicodeUTF8)
    @showOwnership.text = Qt::Application.translate("RelationsConfig", "Show ownership", nil, Qt::Application::UnicodeUTF8)
    @lblRemovedPrefixes.text = Qt::Application.translate("RelationsConfig", "Remove the following prefixes (comma-separated)", nil, Qt::Application::UnicodeUTF8)
    @removedPrefixes.text = Qt::Application.translate("RelationsConfig", "Roby::", nil, Qt::Application::UnicodeUTF8)
    @displayOptionsGroup.title = Qt::Application.translate("RelationsConfig", "Display Options", nil, Qt::Application::UnicodeUTF8)
    @displayExplicit.text = Qt::Application.translate("RelationsConfig", "Explicit hide/show management", nil, Qt::Application::UnicodeUTF8)
    @displayEmitters.text = Qt::Application.translate("RelationsConfig", "Only show tasks that emit events", nil, Qt::Application::UnicodeUTF8)
    @displayEmittersAndParents.text = Qt::Application.translate("RelationsConfig", "Only show tasks that emit events and their parents", nil, Qt::Application::UnicodeUTF8)
    @lblHiddenLabels.text = Qt::Application.translate("RelationsConfig", "Hide tasks whose label matches (comma-separated)", nil, Qt::Application::UnicodeUTF8)
    @showFinalized.text = Qt::Application.translate("RelationsConfig", "Show finalized objects", nil, Qt::Application::UnicodeUTF8)
    @lblLayoutMethod.text = Qt::Application.translate("RelationsConfig", "Layout method", nil, Qt::Application::UnicodeUTF8)
    end # retranslateUi

    def retranslate_ui(relationsConfig)
        retranslateUi(relationsConfig)
    end

end

module Ui
    class RelationsConfig < Ui_RelationsConfig
    end
end  # module Ui

