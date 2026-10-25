# frozen_string_literal: true

require 'rails_helper'

# Backs the contact History tab and the priority list: typed history entries on
# notes, the contact's tasks across deals, and the contacts ordered by urgency.
RSpec.describe 'Contact history and priority', type: :request do
  let(:user) { User.create!(name: 'History Probe', email: "history-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }
  let(:open_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Proposal', position: 1, color: '#F59E0B') }
  let(:won_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Won', position: 2, stage_type: :completed) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
  end

  after { Current.reset }

  def json_response
    response.parsed_body
  end

  def contact_named(name, last_activity_at: nil)
    Contact.create!(name: name).tap { |c| c.update_columns(last_activity_at: last_activity_at) } # rubocop:disable Rails/SkipsModelValidations
  end

  def deal_for(contact, stage: open_stage)
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact)
  end

  def task_for(item, title, due_date)
    PipelineTask.create!(pipeline_item: item, created_by: user, title: title, due_date: due_date)
  end

  describe 'typed notes' do
    let(:contact) { contact_named('Typed') }

    it 'stores kind and occurred_at and returns them' do
      at = 2.days.ago.change(usec: 0)
      post "/api/v1/contacts/#{contact.id}/notes",
           params: { content: 'Ligação de alinhamento', kind: 'call', occurred_at: at.iso8601 }, as: :json

      expect(response).to have_http_status(:created)
      expect(json_response.dig('data', 'kind')).to eq('call')
      expect(Time.zone.parse(json_response.dig('data', 'occurred_at'))).to eq(at)
    end

    it 'defaults to a plain note dated now' do
      post "/api/v1/contacts/#{contact.id}/notes", params: { content: 'só uma nota' }, as: :json

      note = contact.notes.reload.first
      expect(note.kind).to eq('note')
      expect(note.occurred_at).to be_within(1.minute).of(Time.current)
    end

    it 'rejects an unknown kind' do
      post "/api/v1/contacts/#{contact.id}/notes", params: { content: 'x', kind: 'fax' }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(contact.notes.count).to eq(0)
    end

    it 'lists the newest occurrence first' do
      Note.create!(contact: contact, content: 'older', occurred_at: 3.days.ago)
      Note.create!(contact: contact, content: 'newer', occurred_at: 1.hour.ago)

      get "/api/v1/contacts/#{contact.id}/notes", as: :json

      expect(json_response['data'].map { |n| n['content'] }).to eq(%w[newer older])
    end
  end

  describe 'GET /api/v1/contacts/:id/tasks' do
    let(:contact) { contact_named('Tasks') }
    let!(:item) { deal_for(contact) }

    it 'returns open tasks of the contact deals, soonest first, with the stage' do
      later = task_for(item, 'Later', 3.days.from_now)
      sooner = task_for(item, 'Sooner', 1.day.from_now)
      task_for(item, 'Done', 1.day.ago).update!(status: :completed)

      get "/api/v1/contacts/#{contact.id}/tasks", as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |t| t['id'] }).to eq([sooner.id, later.id])
      expect(json_response['data'].first).to include('pipeline_id' => pipeline.id, 'pipeline_name' => 'Sales')
      expect(json_response['data'].first.dig('stage', 'name')).to eq('Proposal')
    end

    it 'includes finished tasks with status=all' do
      task_for(item, 'Done', 1.day.ago).update!(status: :completed)

      get "/api/v1/contacts/#{contact.id}/tasks", params: { status: 'all' }

      expect(json_response['data'].map { |t| t['title'] }).to eq(['Done'])
    end

    it 'hides tasks on a private board of another user' do
      other = User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com")
      pipeline.update!(created_by: other, visibility: :private)
      task_for(item, 'Secret', 1.day.from_now)

      get "/api/v1/contacts/#{contact.id}/tasks", as: :json

      expect(json_response['data']).to eq([])
    end
  end

  describe 'GET /api/v1/contacts/priority' do
    let(:cooling) { contact_named('Cooling', last_activity_at: 12.days.ago) }

    before do
      task_for(deal_for(contact_named('Overdue')), 'Send contract', 2.days.ago)
      task_for(deal_for(contact_named('Due today')), 'Call back', 1.minute.from_now)
      awaiting_conversation(contact_named('Awaiting'), since: 3.hours.ago)
      deal_for(cooling)
      deal_for(contact_named('Warm', last_activity_at: 1.day.ago))
      deal_for(contact_named('Won deal', last_activity_at: 30.days.ago), stage: won_stage)
      contact_named('Nothing pending')
    end

    def awaiting_conversation(contact, since:)
      inbox = Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: Channel::Api.create!)
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8))
      conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      # Set directly: the message pipeline that maintains waiting_since is not under test.
      conversation.update_columns(waiting_since: since, status: Conversation.statuses[:open]) # rubocop:disable Rails/SkipsModelValidations
    end

    it 'leaves out contacts with nothing pending and no open deal' do
      get '/api/v1/contacts/priority', params: { timezone: 'UTC' }

      expect(json_response['data'].map { |r| r['name'] }).not_to include('Won deal', 'Nothing pending')
    end

    it 'orders by group and explains each row' do
      get '/api/v1/contacts/priority', params: { timezone: 'UTC' }

      expect(response).to have_http_status(:ok)
      rows = json_response['data']
      expect(rows.map { |r| r['name'] }).to eq(['Overdue', 'Awaiting', 'Due today', 'Cooling', 'Warm'])
      expect(rows.map { |r| r.dig('priority', 'reason') }).to eq(%w[overdue awaiting due_today cooling none])
      expect(rows.first.dig('priority', 'task', 'title')).to eq('Send contract')
      expect(rows.find { |r| r['name'] == 'Cooling' }.dig('priority', 'stage', 'name')).to eq('Proposal')
    end

    it 'counts each group for the filter chips' do
      get '/api/v1/contacts/priority', params: { timezone: 'UTC' }

      expect(json_response.dig('meta', 'counts')).to eq(
        'all' => 5, 'overdue' => 1, 'today' => 2, 'cooling' => 1, 'ok' => 1
      )
    end

    it 'filters by group' do
      get '/api/v1/contacts/priority', params: { group: 'today', timezone: 'UTC' }

      expect(json_response['data'].map { |r| r['name'] }).to eq(['Awaiting', 'Due today'])
    end

    it 'counts a logged call as a touch, so the contact is no longer cooling' do
      Note.create!(contact: cooling, content: 'Ligação', kind: :call, occurred_at: 1.hour.ago)

      get '/api/v1/contacts/priority', params: { group: 'cooling', timezone: 'UTC' }

      expect(json_response['data']).to eq([])
    end

    it 'searches by name' do
      get '/api/v1/contacts/priority', params: { q: 'cool', timezone: 'UTC' }

      expect(json_response['data'].map { |r| r['name'] }).to eq(['Cooling'])
    end

    it 'sorts by name on request' do
      get '/api/v1/contacts/priority', params: { sort: 'name', timezone: 'UTC' }

      expect(json_response['data'].map { |r| r['name'] }).to eq(
        ['Awaiting', 'Cooling', 'Due today', 'Overdue', 'Warm']
      )
    end
  end
end
