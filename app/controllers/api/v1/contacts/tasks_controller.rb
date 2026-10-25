# frozen_string_literal: true

# Tasks of every deal the contact is on, so the contact screen can show them in
# one card. Writes go through the pipeline task routes, which own the rules.
class Api::V1::Contacts::TasksController < Api::V1::Contacts::BaseController
  require_permissions({ index: 'contacts.read' })

  OPEN_STATUSES = %w[pending overdue].freeze

  def index
    tasks = PipelineTask.root_tasks
                        .where(pipeline_item_id: visible_items.select(:id))
                        .includes(:created_by, :assigned_to, pipeline_item: [:pipeline, :pipeline_stage])
    tasks = tasks.where(status: OPEN_STATUSES) unless params[:status] == 'all'
    tasks = tasks.order(Arel.sql('pipeline_tasks.due_date ASC NULLS LAST, pipeline_tasks.created_at ASC'))

    success_response(
      data: tasks.map { |task| task_json(task) },
      message: 'Contact tasks retrieved successfully'
    )
  end

  private

  # A deal belongs to the contact directly (lead card) or through one of its
  # conversations; boards the user cannot see stay hidden, as on the pipeline screens.
  def visible_items
    PipelineItem.where(pipeline_id: policy_scope(Pipeline).select(:id))
                .where('pipeline_items.contact_id = :id OR pipeline_items.conversation_id IN (:conversations)',
                       id: @contact.id, conversations: @contact.conversations.select(:id))
  end

  def task_json(task)
    item = task.pipeline_item
    PipelineTaskSerializer.serialize(task).merge(
      pipeline_id: item.pipeline_id,
      pipeline_name: item.pipeline&.name,
      stage: item.pipeline_stage && {
        id: item.pipeline_stage.id,
        name: item.pipeline_stage.name,
        color: item.pipeline_stage.color,
        stage_type: item.pipeline_stage.stage_type
      }
    )
  end
end
