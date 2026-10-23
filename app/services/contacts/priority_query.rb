# frozen_string_literal: true

# Orders the contacts that need attention, most urgent first. Each contact lands
# in exactly one group, checked in this order:
#
#   overdue - an open task is past its due date
#   today   - a conversation waits for our reply, or a task is due later today
#   cooling - an open deal and no touch for COLD_AFTER_DAYS
#   ok      - the rest (next task first, then contacts with nothing pending)
#
# Only contacts with an open task, an open deal or a waiting conversation are
# candidates; the plain contacts table still lists everyone.
module Contacts
  class PriorityQuery
    GROUPS = %w[overdue today cooling ok].freeze
    COLD_AFTER_DAYS = 7
    FAR_FUTURE = Time.utc(9999)

    attr_reader :now, :day_end

    def initialize(base:, pipelines:, time_zone: Time.zone, now: Time.current)
      @base = base
      @pipelines = pipelines
      @now = now
      @day_end = now.in_time_zone(time_zone).end_of_day
    end

    # Annotated contacts, before the group filter (the chips count over this).
    def relation(search: nil)
      scope = Contact.from("(#{annotated_sql}) AS contacts")
      return scope if search.blank?

      scope.where(
        "contacts.name ILIKE :q OR contacts.email ILIKE :q OR contacts.phone_number ILIKE :q
          OR contacts.additional_attributes->>'company_name' ILIKE :q",
        q: "%#{Contact.sanitize_sql_like(search.strip)}%"
      )
    end

    def self.filter(scope, group)
      return scope unless GROUPS.include?(group)

      scope.where(priority_rank: GROUPS.index(group))
    end

    def self.order(scope, sort)
      case sort
      when 'recent' then scope.order(Arel.sql('contacts.last_contact_at DESC NULLS LAST, contacts.id'))
      when 'name' then scope.order(Arel.sql('LOWER(contacts.name), contacts.id'))
      else scope.order(Arel.sql(PRIORITY_ORDER))
      end
    end

    # Waiting conversations go before tasks due today; cooling contacts never
    # touched go first; within ok, contacts with no next task go last, most
    # recently touched first.
    PRIORITY_ORDER = <<~SQL.squish
      contacts.priority_rank,
      (contacts.priority_rank = 1 AND contacts.awaiting_since IS NULL),
      CASE contacts.priority_rank
        WHEN 0 THEN contacts.overdue_at
        WHEN 1 THEN COALESCE(contacts.awaiting_since, contacts.today_at)
        WHEN 2 THEN COALESCE(contacts.last_contact_at, '-infinity'::timestamp)
        ELSE contacts.next_at
      END NULLS LAST,
      contacts.last_contact_at DESC NULLS LAST,
      contacts.id
    SQL

    # %<pipelines>s and %<base>s take the visible pipelines and listable contacts
    # subqueries; :now, :day_end and :cold_before are bound by annotated_sql.
    ANNOTATED_SQL = <<~SQL.squish
      WITH contact_items AS (
        SELECT pi.id, pi.pipeline_stage_id, pi.completed_at,
               COALESCE(pi.contact_id, conv.contact_id) AS contact_id
        FROM pipeline_items pi
        LEFT JOIN conversations conv ON conv.id = pi.conversation_id
        WHERE pi.pipeline_id IN (%<pipelines>s)
      ),
      task_agg AS (
        SELECT ci.contact_id,
               MIN(t.due_date) FILTER (WHERE t.due_date < :now) AS overdue_at,
               MIN(t.due_date) FILTER (WHERE t.due_date >= :now AND t.due_date <= :day_end) AS today_at,
               MIN(t.due_date) FILTER (WHERE t.due_date >= :now) AS next_at
        FROM pipeline_tasks t
        JOIN contact_items ci ON ci.id = t.pipeline_item_id
        WHERE t.parent_task_id IS NULL AND t.status IN (0, 3)
        GROUP BY ci.contact_id
      ),
      deal_agg AS (
        SELECT DISTINCT ci.contact_id
        FROM contact_items ci
        JOIN pipeline_stages ps ON ps.id = ci.pipeline_stage_id
        WHERE ci.completed_at IS NULL AND ps.stage_type = 0
      ),
      waiting AS (
        SELECT contact_id, MIN(waiting_since) AS awaiting_since
        FROM conversations
        WHERE status = 0 AND waiting_since IS NOT NULL AND contact_id IS NOT NULL
        GROUP BY contact_id
      ),
      candidates AS (
        SELECT contact_id FROM task_agg
        UNION SELECT contact_id FROM deal_agg
        UNION SELECT contact_id FROM waiting
      ),
      annotated AS (
        SELECT contacts.*,
               task_agg.overdue_at, task_agg.today_at, task_agg.next_at,
               waiting.awaiting_since,
               (deal_agg.contact_id IS NOT NULL) AS open_deal,
               GREATEST(contacts.last_activity_at, touches.touched_at) AS last_contact_at
        FROM contacts
        JOIN candidates ON candidates.contact_id = contacts.id
        LEFT JOIN task_agg ON task_agg.contact_id = contacts.id
        LEFT JOIN waiting ON waiting.contact_id = contacts.id
        LEFT JOIN deal_agg ON deal_agg.contact_id = contacts.id
        LEFT JOIN LATERAL (
          SELECT MAX(notes.occurred_at) AS touched_at
          FROM notes
          WHERE notes.contact_id = contacts.id AND notes.kind <> 0
        ) touches ON TRUE
        WHERE contacts.id IN (%<base>s)
      )
      SELECT annotated.*,
             CASE
               WHEN overdue_at IS NOT NULL THEN 0
               WHEN awaiting_since IS NOT NULL OR today_at IS NOT NULL THEN 1
               WHEN open_deal AND (last_contact_at IS NULL OR last_contact_at < :cold_before) THEN 2
               ELSE 3
             END AS priority_rank
      FROM annotated
    SQL

    def counts(scope)
      by_rank = scope.unscope(:order).group('contacts.priority_rank').count
      GROUPS.each_with_index.to_h { |group, rank| [group, by_rank.fetch(rank, 0)] }
            .merge('all' => by_rank.values.sum)
    end

    # The reason line names the task and the stage behind each rank; loaded for
    # one page only. Returns { contact_id => priority hash }.
    def priorities_for(contacts)
      items = items_for(contacts.map(&:id))
      tasks = open_tasks_by_item(items)
      owned = items.group_by { |item| item.contact_id || item.conversation&.contact_id }
      contacts.to_h { |contact| [contact.id, priority_for(contact, owned.fetch(contact.id, []), tasks)] }
    end

    private

    def annotated_sql
      sql = format(ANNOTATED_SQL, pipelines: @pipelines.select(:id).to_sql, base: @base.select(:id).to_sql)
      Contact.sanitize_sql_array([sql, { now: now, day_end: day_end, cold_before: now - COLD_AFTER_DAYS.days }])
    end

    def items_for(contact_ids)
      PipelineItem.where(pipeline_id: @pipelines.select(:id))
                  .left_joins(:conversation)
                  .where('pipeline_items.contact_id IN (:ids) OR conversations.contact_id IN (:ids)', ids: contact_ids)
                  .includes(:pipeline, :pipeline_stage, :conversation)
                  .to_a
    end

    def open_tasks_by_item(items)
      PipelineTask.root_tasks
                  .where(pipeline_item_id: items.map(&:id), status: %w[pending overdue])
                  .group_by(&:pipeline_item_id)
    end

    def priority_for(contact, items, tasks_by_item)
      tasks = items.flat_map { |item| tasks_by_item.fetch(item.id, []) }.sort_by { |t| t.due_date || FAR_FUTURE }
      task = reason_task(contact, tasks)
      {
        group: GROUPS[contact.priority_rank],
        reason: reason(contact, task),
        task: task && task_json(task, items),
        awaiting_since: contact.awaiting_since&.iso8601,
        last_contact_at: contact.last_contact_at&.iso8601,
        open_tasks_count: tasks.size,
        stage: stage_json(items)
      }
    end

    # The task the reason line names: the most overdue one, or the next one due.
    def reason_task(contact, tasks)
      overdue, upcoming = tasks.select(&:due_date).partition { |task| task.due_date < now }
      case contact.priority_rank
      when 0 then overdue.first
      when 1 then upcoming.first unless contact.awaiting_since
      when 3 then upcoming.first
      end
    end

    def reason(contact, task)
      case contact.priority_rank
      when 0 then 'overdue'
      when 1 then contact.awaiting_since ? 'awaiting' : 'due_today'
      when 2 then 'cooling'
      else task ? 'next' : 'none'
      end
    end

    def task_json(task, items)
      item = items.find { |candidate| candidate.id == task.pipeline_item_id }
      { id: task.id, title: task.title, due_date: task.due_date&.iso8601,
        pipeline_id: item.pipeline_id, pipeline_item_id: item.id }
    end

    # The open deal's stage, shown as the row's pill.
    def stage_json(items)
      deal = items.find { |item| item.completed_at.nil? && item.pipeline_stage&.stage_active? }
      return unless deal

      { name: deal.pipeline_stage.name, color: deal.pipeline_stage.color, pipeline_name: deal.pipeline&.name }
    end
  end
end
