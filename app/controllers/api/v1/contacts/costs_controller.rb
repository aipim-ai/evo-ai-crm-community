# frozen_string_literal: true

# Costs sent to a contact (the "Costs sent" tab). Same permissions as notes:
# reading the contact lets you see them, updating it lets you log or fix one.
class Api::V1::Contacts::CostsController < Api::V1::Contacts::BaseController
  require_permissions({
    index: 'contacts.read',
    create: 'contacts.update',
    update: 'contacts.update',
    destroy: 'contacts.update'
  })

  PERMITTED = %i[sent_on product_code color package_size unit unit_price currency recipient notes].freeze

  wrap_parameters :cost, include: PERMITTED, format: [:json]
  before_action :cost, only: [:update, :destroy]

  def index
    costs = @contact.costs.latest.includes(:user)
    success_response(data: costs.map { |cost| cost_json(cost) }, message: 'Contact costs retrieved successfully')
  end

  def create
    cost = @contact.costs.create!(cost_params.merge(user_id: Current.user&.id))
    success_response(data: cost_json(cost), status: :created, message: 'Cost logged successfully')
  end

  def update
    @cost.update!(cost_params)
    success_response(data: cost_json(@cost), message: 'Cost updated successfully')
  end

  def destroy
    @cost.destroy!
    success_response(data: {}, message: 'Cost deleted successfully')
  end

  private

  def cost
    @cost ||= @contact.costs.find(params[:id])
  end

  def cost_params
    params.require(:cost).permit(*PERMITTED)
  end

  def cost_json(cost)
    {
      id: cost.id,
      contact_id: cost.contact_id,
      sent_on: cost.sent_on.iso8601,
      product_code: cost.product_code,
      color: cost.color,
      package_size: cost.package_size.to_f,
      unit: cost.unit,
      unit_price: cost.unit_price.to_f,
      currency: cost.currency,
      recipient: cost.recipient,
      notes: cost.notes,
      user: cost.user && { id: cost.user.id, name: cost.user.name },
      created_at: cost.created_at.iso8601,
      updated_at: cost.updated_at.iso8601
    }
  end
end
