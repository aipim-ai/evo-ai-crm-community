# frozen_string_literal: true

require 'rails_helper'

# Backs the contact "Costs sent" tab: prices sent to a customer per product,
# packaging and date, in any allowed currency and unit.
RSpec.describe 'Contact costs', type: :request do
  let(:user) { User.create!(name: 'Cost Probe', email: "costs-#{SecureRandom.hex(4)}@example.com") }
  let(:contact) { Contact.create!(name: 'Laboratório Aurora') }
  let(:base) { "/api/v1/contacts/#{contact.id}/costs" }

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

  def cost_for(target, **attrs)
    ContactCost.create!({ contact: target, sent_on: Date.current, product_code: 'BD 11300', package_size: 5,
                          unit_price: 242.5 }.merge(attrs))
  end

  describe 'POST' do
    it 'logs a cost with BRL and kg by default, for the current user' do
      post base, params: { sent_on: '2026-11-20', product_code: ' bd  11300 ', color: 'Pérola champagne',
                           package_size: '5', unit_price: '242.50', recipient: 'Helena' }, as: :json

      expect(response).to have_http_status(:created)
      data = json_response['data']
      expect(data).to include('sent_on' => '2026-11-20', 'product_code' => 'BD 11300', 'currency' => 'BRL',
                              'unit' => 'kg', 'package_size' => 5.0, 'unit_price' => 242.5, 'recipient' => 'Helena')
      expect(data.dig('user', 'id')).to eq(user.id)
    end

    it 'accepts another currency and unit' do
      post base, params: { sent_on: Date.current.iso8601, product_code: 'DP 4020', package_size: 200, unit: 'g',
                           unit_price: 1.5, currency: 'usd' }, as: :json

      expect(response).to have_http_status(:created)
      expect(json_response['data']).to include('currency' => 'USD', 'unit' => 'g', 'package_size' => 200.0)
    end

    it 'rejects an unknown unit or currency and a non-positive price' do
      [{ unit: 'lb' }, { currency: 'GBP' }, { unit_price: 0 }, { package_size: -1 }, { product_code: ' ' }].each do |bad|
        post base, params: { sent_on: Date.current.iso8601, product_code: 'X 1', package_size: 1, unit_price: 1 }.merge(bad),
                   as: :json
        expect(response).to have_http_status(:unprocessable_entity), "expected #{bad} to be rejected"
      end
      expect(contact.costs.count).to eq(0)
    end
  end

  describe 'GET' do
    it 'lists only this contact, newest send first' do
      cost_for(contact, sent_on: 10.days.ago.to_date, product_code: 'OLD 1')
      cost_for(contact, sent_on: 1.day.ago.to_date, product_code: 'NEW 1')
      cost_for(Contact.create!(name: 'Outro'), product_code: 'OTHER')

      get base, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |c| c['product_code'] }).to eq(['NEW 1', 'OLD 1'])
    end
  end

  describe 'PATCH and DELETE' do
    let!(:cost) { cost_for(contact) }

    it 'updates a cost' do
      patch "#{base}/#{cost.id}", params: { unit_price: 230, currency: 'EUR' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(cost.reload).to have_attributes(unit_price: 230, currency: 'EUR')
    end

    it 'deletes a cost' do
      delete "#{base}/#{cost.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(ContactCost.exists?(cost.id)).to be(false)
    end

    it 'does not reach a cost of another contact' do
      other = Contact.create!(name: 'Outro')
      delete "/api/v1/contacts/#{other.id}/costs/#{cost.id}", as: :json

      expect(response).to have_http_status(:not_found)
      expect(ContactCost.exists?(cost.id)).to be(true)
    end
  end

  it 'goes away with the contact' do
    cost = cost_for(contact)
    contact.destroy!
    expect(ContactCost.exists?(cost.id)).to be(false)
  end
end
