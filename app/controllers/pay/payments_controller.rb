module Pay
  class PaymentsController < ApplicationController
    layout "pay/application"

    def show
      @redirect_to = params[:back].presence || root_path
      @payment = Payment.from_id(params[:id], {stripe_account: ActsAsTenant.current_tenant.stripe_account_id})
    end
  end
end
