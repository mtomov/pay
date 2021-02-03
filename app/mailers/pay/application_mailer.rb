module Pay
  class ApplicationMailer < ::ApplicationMailer
    default from: Pay.support_email
    layout "mailer"
  end
end
