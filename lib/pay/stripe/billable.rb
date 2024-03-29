module Pay
  module Stripe
    module Billable
      extend ActiveSupport::Concern

      included do
        scope :stripe, -> { where(processor: :stripe) }
      end

      # Handles Billable#customer
      #
      # Returns Stripe::Customer
      def stripe_customer
        if processor_id?
          ::Stripe::Customer.retrieve(processor_id, default_opts)
        else
          create_stripe_customer
        end
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      def create_setup_intent
        ::Stripe::SetupIntent.create({
          customer: processor_id,
          usage: :off_session
        }, default_opts)
      end

      # Handles Billable#charge
      #
      # Returns Pay::Charge
      def create_stripe_charge(amount, options = {})
        customer = stripe_customer
        args = {
          amount: amount,
          confirm: true,
          confirmation_method: :automatic,
          currency: "usd",
          customer: customer.id,
          payment_method: customer.invoice_settings.default_payment_method
        }.merge(options)

        payment_intent = ::Stripe::PaymentIntent.create(args, default_opts)
        Pay::Payment.new(payment_intent).validate

        # Create a new charge object
        Stripe::Webhooks::ChargeSucceeded.new.create_charge(self, payment_intent.charges.first)
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      # Handles Billable#subscribe
      #
      # Returns Pay::Subscription
      def create_stripe_subscription(name, plan, options = {})
        quantity = options.delete(:quantity) || 1
        args = {
          expand: ["pending_setup_intent", "latest_invoice.payment_intent"],
          items: [plan: plan, quantity: quantity],
          off_session: true
        }.merge(options)

        # Inherit trial from plan unless trial override was specified
        args[:trial_from_plan] = true unless args[:trial_period_days]

        args[:customer] = stripe_customer.id

        stripe_sub = ::Stripe::Subscription.create(args, default_opts)
        subscription = create_subscription(stripe_sub, "stripe", name, plan, status: stripe_sub.status, quantity: quantity)

        # No trial, card requires SCA
        if subscription.incomplete?
          Pay::Payment.new(stripe_sub.latest_invoice.payment_intent).validate

        # Trial, card requires SCA
        elsif subscription.on_trial? && stripe_sub.pending_setup_intent
          Pay::Payment.new(stripe_sub.pending_setup_intent).validate
        end

        subscription
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      # Handles Billable#update_card
      #
      # Returns true if successful
      def update_stripe_card(payment_method_id)
        customer = stripe_customer

        return true if payment_method_id == customer.invoice_settings.default_payment_method

        payment_method = ::Stripe::PaymentMethod.attach(payment_method_id, {customer: customer.id}, default_opts)
        ::Stripe::Customer.update(customer.id, {invoice_settings: {default_payment_method: payment_method.id}}, default_opts)

        update_stripe_card_on_file(payment_method.card)
        true
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      def update_stripe_email!
        customer = stripe_customer
        customer.email = email
        customer.name = customer_name
        customer.save
      end

      def stripe_subscription(subscription_id, options = {})
        ::Stripe::Subscription.retrieve(options.merge(id: subscription_id), default_opts)
      end

      def stripe_invoice!(options = {})
        return unless processor_id?
        ::Stripe::Invoice.create(options.merge(customer: processor_id), default_opts).pay
      end

      def stripe_upcoming_invoice
        ::Stripe::Invoice.upcoming({customer: processor_id}, default_opts)
      end

      # Used by webhooks when the customer or source changes
      def sync_card_from_stripe
        # we don't update cards on connected accounts as they
        # are meant to be clones of the cards on the platform
        return if connected_account_id.present?

        stripe_cust = stripe_customer
        default_payment_method_id = stripe_cust.invoice_settings.default_payment_method

        if default_payment_method_id.present?
          payment_method = ::Stripe::PaymentMethod.retrieve(default_payment_method_id)
          update(
            card_type: payment_method.card.brand,
            card_last4: payment_method.card.last4,
            card_exp_month: payment_method.card.exp_month,
            card_exp_year: payment_method.card.exp_year
          )

        # Customer has no default payment method
        else
          update(card_type: nil, card_last4: nil)
        end
      end

      private

      def default_opts
        opts = {}
        opts[:stripe_account] = connected_account_id if connected_account_id
        opts
      end

      def create_stripe_customer
        customer = ::Stripe::Customer.create({email: email, name: customer_name}, default_opts)

        # Update the user's card on file if a token was passed in
        if card_token.present?
          payment_method = ::Stripe::PaymentMethod.attach(card_token, {customer: customer.id}, default_opts)
          customer.invoice_settings.default_payment_method = payment_method.id
          customer.save

          update_stripe_card_on_file ::Stripe::PaymentMethod.retrieve(card_token, default_opts).card
        end

        update(processor: "stripe", processor_id: customer.id)

        customer
      end

      def stripe_trial_end_date(stripe_sub)
        # Times in Stripe are returned in UTC
        stripe_sub.trial_end.present? ? Time.at(stripe_sub.trial_end) : nil
      end

      def stripe_current_period_end_date(stripe_sub)
        # Times in Stripe are returned in UTC
        stripe_sub.current_period_end.present? ? Time.at(stripe_sub.current_period_end) : nil
      end

      def stripe_current_period_start_date(stripe_sub)
        # Times in Stripe are returned in UTC
        stripe_sub.current_period_start.present? ? Time.at(stripe_sub.current_period_start) : nil
      end

      # Save the card to the database as the user's current card
      def update_stripe_card_on_file(card)
        # Not possible as we don't store cloned card details on connected accounts
        return if connected_account_id.present?

        update!(
          card_type: card.brand.capitalize,
          card_last4: card.last4,
          card_exp_month: card.exp_month,
          card_exp_year: card.exp_year
        )

        self.card_token = nil
      end
    end
  end
end
