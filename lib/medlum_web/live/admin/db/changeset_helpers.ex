defmodule MedlumWeb.Admin.Db.ChangesetHelpers do
  @moduledoc """
  Helper functions to wrap arity-2 changesets to arity-3 for Backpex compatibility.
  """

  # User
  def user_changeset(user, attrs, _metadata),
    do: Medlum.Accounts.User.email_changeset(user, attrs)

  # Tenant
  def tenant_changeset(tenant, attrs, _metadata),
    do: Medlum.Tenancy.Tenant.changeset(tenant, attrs)

  # Patient
  def patient_changeset(patient, attrs, _metadata),
    do: Medlum.Clinical.Patient.changeset(patient, attrs)

  # ReportRun
  def report_run_changeset(run, attrs, _metadata),
    do: Medlum.Reports.ReportRun.changeset(run, attrs)

  # ReportSectionRun
  def report_section_run_changeset(run, attrs, _metadata),
    do: Medlum.Reports.ReportSectionRun.changeset(run, attrs)

  # ReportTemplate
  def report_template_changeset(template, attrs, _metadata),
    do: Medlum.Reports.ReportTemplate.changeset(template, attrs)

  # ReportSectionTemplate
  def report_section_template_changeset(section, attrs, _metadata),
    do: Medlum.Reports.ReportSectionTemplate.changeset(section, attrs)

  # LlmInvocation
  def llm_invocation_changeset(invocation, attrs, _metadata),
    do: Medlum.AI.LlmInvocation.changeset(invocation, attrs)

  # DocumentUpload
  def document_upload_changeset(upload, attrs, _metadata),
    do: Medlum.Documents.DocumentUpload.changeset(upload, attrs)

  # IngestionJob
  def ingestion_job_changeset(job, attrs, _metadata),
    do: Medlum.Documents.IngestionJob.changeset(job, attrs)
end
