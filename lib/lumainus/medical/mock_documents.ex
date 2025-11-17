defmodule LumainusWeb.Medical.MockDocuments do
  @moduledoc """
  Mock medical documents for UI development.
  No database - all data in memory for prototyping.
  """

  defmodule Document do
    @type t :: %__MODULE__{
            id: String.t(),
            type: String.t(),
            date: Date.t(),
            provider: String.t(),
            summary: String.t(),
            raw_content: String.t(),
            cleaned_content: String.t()
          }

    defstruct [:id, :type, :date, :provider, :summary, :raw_content, :cleaned_content]
  end

  defmodule Report do
    @type t :: %__MODULE__{
            patient_name: String.t(),
            patient_mrn: String.t(),
            chief_complaint: String.t(),
            hpi: map(),
            medications: list(map()),
            past_exam_findings: String.t(),
            review_of_systems: String.t(),
            labs: list(map()),
            imaging: list(map()),
            pathology: list(map()),
            assessment: String.t(),
            plan: String.t()
          }

    defstruct [
      :patient_name,
      :patient_mrn,
      :chief_complaint,
      :hpi,
      :medications,
      :past_exam_findings,
      :review_of_systems,
      :labs,
      :imaging,
      :pathology,
      :assessment,
      :plan
    ]
  end

  @doc """
  Returns list of mock documents for testing
  """
  def list_documents do
    [
      %Document{
        id: "doc-001",
        type: "Doctor's Note - Primary Care",
        date: ~D[2024-11-10],
        provider: "Dr. Sarah Chen, MD",
        summary:
          "Annual physical exam with complaints of fatigue and occasional chest discomfort. Patient reports 3-month history of decreased energy.",
        raw_content: """
        PATIENT: John Doe, MRN: 123456789
        DATE: November 10, 2024
        PROVIDER: Dr. Sarah Chen, MD

        CHIEF COMPLAINT: Fatigue and occasional chest discomfort

        HPI: 58-year-old male presents with 3-month history of progressive fatigue...
        Patient denies shortness of breath at rest but notes mild dyspnea on exertion...
        Chest discomfort described as pressure-like, non-radiating, intermittent...
        """,
        cleaned_content: """
        # Primary Care Visit - Annual Physical

        **Date:** November 10, 2024
        **Provider:** Dr. Sarah Chen, MD

        ## Chief Complaint
        Fatigue and occasional chest discomfort

        ## History of Present Illness
        58-year-old male with 3-month progressive fatigue history.
        - Denies SOB at rest
        - Mild dyspnea on exertion
        - Chest discomfort: pressure-like, non-radiating, intermittent
        """
      },
      %Document{
        id: "doc-002",
        type: "Cardiology Consultation",
        date: ~D[2024-11-12],
        provider: "Dr. Michael Torres, Cardiology",
        summary:
          "Cardiology consultation for chest discomfort. EKG showed nonspecific T-wave changes. Stress test recommended.",
        raw_content: """
        CARDIOLOGY CONSULTATION
        Patient: John Doe, MRN: 123456789
        Date: November 12, 2024
        Cardiologist: Dr. Michael Torres

        REASON FOR CONSULTATION: Evaluation of chest discomfort

        EKG: Nonspecific T-wave changes in lateral leads...
        ASSESSMENT: Atypical chest pain, low-intermediate cardiac risk...
        """,
        cleaned_content: """
        # Cardiology Consultation

        **Date:** November 12, 2024
        **Provider:** Dr. Michael Torres, Cardiology

        ## Findings
        - EKG: Nonspecific T-wave changes (lateral leads)
        - Atypical chest pain pattern
        - Low-intermediate cardiac risk
        """
      },
      %Document{
        id: "doc-003",
        type: "Lab Report - Lipid Panel",
        date: ~D[2024-11-11],
        provider: "Quest Diagnostics",
        summary:
          "Lipid panel showing elevated LDL cholesterol (165 mg/dL) and low HDL (38 mg/dL).",
        raw_content: """
        LABORATORY REPORT
        Patient: John Doe
        Date Collected: November 11, 2024

        LIPID PANEL
        Total Cholesterol: 245 mg/dL (High)
        LDL: 165 mg/dL (High)
        HDL: 38 mg/dL (Low)
        Triglycerides: 210 mg/dL (High)
        """,
        cleaned_content: """
        # Lipid Panel Results

        **Date:** November 11, 2024

        | Test | Value | Reference | Flag |
        |------|-------|-----------|------|
        | Total Cholesterol | 245 mg/dL | <200 | High |
        | LDL | 165 mg/dL | <100 | High |
        | HDL | 38 mg/dL | >40 | Low |
        | Triglycerides | 210 mg/dL | <150 | High |
        """
      },
      %Document{
        id: "doc-004",
        type: "Radiology - Chest X-Ray",
        date: ~D[2024-11-13],
        provider: "Dr. Lisa Park, Radiology",
        summary: "Chest X-ray shows mild cardiomegaly. No acute infiltrates. Lungs are clear.",
        raw_content: """
        RADIOLOGY REPORT - CHEST X-RAY (PA and Lateral)
        Patient: John Doe, MRN: 123456789
        Date: November 13, 2024
        Radiologist: Dr. Lisa Park

        FINDINGS:
        Heart size is mildly enlarged (cardiothoracic ratio 0.55).
        Lungs are clear bilaterally without infiltrate or effusion.
        No pneumothorax. Bony structures intact.

        IMPRESSION: Mild cardiomegaly. Otherwise unremarkable chest radiograph.
        """,
        cleaned_content: """
        # Chest X-Ray Report

        **Date:** November 13, 2024
        **Radiologist:** Dr. Lisa Park

        ## Findings
        - Mild cardiomegaly (CTR 0.55)
        - Lungs clear bilaterally
        - No infiltrate or effusion
        - No pneumothorax

        ## Impression
        Mild cardiomegaly. Otherwise unremarkable.
        """
      },
      %Document{
        id: "doc-005",
        type: "Hospital Discharge Summary",
        date: ~D[2024-10-15],
        provider: "University Hospital",
        summary:
          "Admission for pneumonia. Treated with antibiotics. Discharged in stable condition after 3 days.",
        raw_content: """
        DISCHARGE SUMMARY
        Patient: John Doe, MRN: 123456789
        Admission Date: October 12, 2024
        Discharge Date: October 15, 2024

        ADMISSION DIAGNOSIS: Community-acquired pneumonia

        HOSPITAL COURSE:
        Patient admitted with fever, cough, and dyspnea. CXR showed RLL infiltrate.
        Treated with ceftriaxone and azithromycin. Clinical improvement by day 2.
        Afebrile x 48 hours. Oxygen saturation 96% on room air at discharge.

        DISCHARGE MEDICATIONS:
        1. Amoxicillin 875mg PO BID x 7 days
        2. Continue home medications
        """,
        cleaned_content: """
        # Hospital Discharge Summary

        **Admission:** October 12-15, 2024 (3 days)
        **Facility:** University Hospital

        ## Diagnosis
        Community-acquired pneumonia (RLL)

        ## Treatment
        - IV Ceftriaxone + Azithromycin
        - Clinical improvement by day 2
        - Afebrile x 48h before discharge

        ## Discharge Status
        - O2 Sat: 96% on room air
        - Condition: Stable
        """
      },
      %Document{
        id: "doc-006",
        type: "Specialist Note - Infectious Disease",
        date: ~D[2024-10-14],
        provider: "Dr. James Liu, Infectious Disease",
        summary: "ID consultation during hospital stay. Recommended extended antibiotic course.",
        raw_content: """
        INFECTIOUS DISEASE CONSULTATION
        Patient: John Doe
        Date: October 14, 2024
        Consultant: Dr. James Liu

        REASON: Pneumonia management

        RECOMMENDATIONS:
        - Blood cultures negative x 2
        - Urine legionella antigen negative
        - Continue current antibiotic regimen
        - Complete 10-day total course
        - Follow-up in ID clinic if not improved in 2 weeks
        """,
        cleaned_content: """
        # Infectious Disease Consultation

        **Date:** October 14, 2024
        **Provider:** Dr. James Liu

        ## Workup
        - Blood cultures: Negative (x2)
        - Urine legionella: Negative

        ## Recommendations
        - Continue antibiotics (10-day total)
        - F/U in ID clinic if no improvement (2 weeks)
        """
      }
    ]
  end

  @doc """
  Returns mock report generated from documents
  """
  def get_report do
    %Report{
      patient_name: "John Doe",
      patient_mrn: "123456789",
      chief_complaint: "Fatigue and occasional chest discomfort (3-month history)|source:doc-001",
      hpi: %{
        present_illness:
          "58-year-old male presents with progressive fatigue over 3 months|source:doc-001. Denies shortness of breath at rest|source:doc-001 but notes mild dyspnea on exertion|source:doc-001. Chest discomfort described as pressure-like, non-radiating, and intermittent|source:doc-001,doc-002.",
        past_medical_history:
          "Recent hospitalization for community-acquired pneumonia|source:doc-005 (October 2024), treated successfully with antibiotics.",
        past_surgical_history: "None documented",
        social_history: "Details not provided in available documents"
      },
      medications: [
        %{
          name: "Amoxicillin 875mg PO BID",
          indication: "Pneumonia treatment completion|source:doc-005",
          status: "Active (7-day course)"
        },
        %{
          name: "Home medications",
          indication: "Continued from prior|source:doc-005",
          status: "Active (details not specified)"
        }
      ],
      past_exam_findings:
        "Recent physical exam findings not fully documented in available records. Cardiac exam during cardiology consultation pending|source:doc-002.",
      review_of_systems:
        "Denies SOB at rest|source:doc-001. Mild dyspnea on exertion|source:doc-001. Intermittent chest pressure|source:doc-001. Recent history of cough and fever (resolved)|source:doc-005.",
      labs: [
        %{
          test: "Lipid Panel",
          date: "2024-11-11|source:doc-003",
          findings: """
          - Total Cholesterol: 245 mg/dL (High)|source:doc-003
          - LDL: 165 mg/dL (High)|source:doc-003
          - HDL: 38 mg/dL (Low)|source:doc-003
          - Triglycerides: 210 mg/dL (High)|source:doc-003
          """
        },
        %{
          test: "Blood Cultures",
          date: "2024-10-14|source:doc-006",
          findings: "Negative x2|source:doc-006"
        },
        %{
          test: "Urine Legionella Antigen",
          date: "2024-10-14|source:doc-006",
          findings: "Negative|source:doc-006"
        }
      ],
      imaging: [
        %{
          study: "Chest X-Ray",
          date: "2024-11-13|source:doc-004",
          findings: """
          - Mild cardiomegaly (cardiothoracic ratio 0.55)|source:doc-004
          - Lungs clear bilaterally|source:doc-004
          - No infiltrate or effusion|source:doc-004
          - No pneumothorax|source:doc-004
          """,
          impression: "Mild cardiomegaly. Otherwise unremarkable.|source:doc-004"
        },
        %{
          study: "Chest X-Ray (Hospital Admission)",
          date: "2024-10-12|source:doc-005",
          findings: "Right lower lobe infiltrate|source:doc-005",
          impression: "Community-acquired pneumonia|source:doc-005"
        }
      ],
      pathology: [],
      assessment: """
      1. Atypical chest pain with dyslipidemia and mild cardiomegaly|source:doc-002,doc-003,doc-004
         - Low-intermediate cardiac risk|source:doc-002
         - EKG shows nonspecific T-wave changes|source:doc-002
         - Elevated LDL (165 mg/dL) and low HDL (38 mg/dL)|source:doc-003
         - Mild cardiomegaly on chest X-ray|source:doc-004

      2. Recent community-acquired pneumonia (resolved)|source:doc-005
         - Currently completing antibiotic course|source:doc-005
         - Clinical improvement noted|source:doc-005,doc-006

      3. Dyslipidemia requiring management|source:doc-003

      4. Fatigue - etiology unclear, may be related to recent illness or cardiac concerns|source:doc-001
      """,
      plan: """
      1. Cardiac Workup|source:doc-002
         - Stress test (recommended by cardiology)|source:doc-002
         - Consider echocardiogram for cardiomegaly evaluation|source:doc-004
         - Follow-up with cardiology

      2. Dyslipidemia Management|source:doc-003
         - Initiate statin therapy (discuss with PCP)
         - Lifestyle modifications (diet, exercise)
         - Repeat lipid panel in 3 months

      3. Pneumonia Follow-up|source:doc-005,doc-006
         - Complete amoxicillin course (7 days remaining)|source:doc-005
         - Follow-up in ID clinic if no continued improvement|source:doc-006
         - Repeat chest X-ray in 6 weeks to confirm resolution

      4. Primary Care Follow-up|source:doc-001
         - Address fatigue concerns
         - Monitor for symptom changes
         - Coordinate specialist care
      """
    }
  end
end
