defmodule Lumainus.Documents.SampleData do
  @moduledoc """
  Synthetic clinical documents used to quickly populate a workspace for demos.
  """

  @samples [
    %{
      slug: "er-intake",
      filename: "emergency_intake_note.pdf",
      mock_id: "doc-101",
      document_kind: "Emergency Dept. Note",
      label: "ED Intake · 12 Jan",
      provider: "Harborview Medical",
      date: "2025-01-12",
      summary:
        "Patient arrived via EMS for substernal chest pain with diaphoresis. Aspirin given en route.",
      lines: [
        %{
          tag: :chief_complaint,
          text:
            "Chief Complaint: Crushing substernal chest pain radiating to left arm for 90 minutes."
        },
        %{
          tag: :history,
          text:
            "History: 58 y/o male with HTN, hyperlipidemia, remote smoking history (quit 2018). No prior MI."
        },
        %{
          tag: :history,
          text:
            "Symptoms began while shoveling snow; associated diaphoresis and mild dyspnea, no syncope."
        },
        %{
          tag: :medications,
          text: "Home meds: lisinopril 20 mg daily, atorvastatin 40 mg nightly, aspirin 81 mg."
        },
        %{tag: :vitals, text: "ED vitals: BP 168/92, HR 104, RR 18, SpO2 97% RA, Temp 36.8 °C."},
        %{
          tag: :assessment,
          text:
            "Initial assessment: Suspected unstable angina vs NSTEMI. TIMI score estimated at 5."
        }
      ]
    },
    %{
      slug: "cardio-diagnostics",
      filename: "cardiology_diagnostics.pdf",
      mock_id: "doc-102",
      document_kind: "Diagnostics Summary",
      label: "Diagnostics · Stress + Biomarkers",
      provider: "Harborview Cardiology",
      date: "2025-01-13",
      summary:
        "Stress echo shows moderate anterior wall hypokinesis. High-sensitivity troponin peaked at 212 ng/L with downtrend.",
      lines: [
        %{
          tag: :labs,
          text: "Labs: hs-Troponin 18 → 212 → 198 ng/L; BNP 62 pg/mL; LDL 142 mg/dL."
        },
        %{
          tag: :imaging,
          text:
            "ECG: Sinus tachycardia with 1 mm ST depression V4-V6, T-wave inversions in inferior leads."
        },
        %{
          tag: :imaging,
          text: "Stress Echo: moderate hypokinesis of anterior wall, EF 45% (baseline 55%)."
        },
        %{
          tag: :procedures,
          text: "CXR: Mild cardiomegaly, clear lung fields. Coronary CTA pending authorization."
        },
        %{
          tag: :recommendations,
          text:
            "Cardiology recommends heparin drip, beta blocker initiation, early invasive strategy if pain recurs."
        }
      ]
    },
    %{
      slug: "assessment-plan",
      filename: "rounding_plan_addendum.pdf",
      mock_id: "doc-103",
      document_kind: "Plan Addendum",
      label: "Plan Addendum · Dr. Rivera",
      provider: "Lumainus Heart Institute",
      date: "2025-01-14",
      summary:
        "Stabilized chest pain overnight. Titrating beta blocker; prepping patient for angiography with informed consent signed.",
      lines: [
        %{
          tag: :assessment,
          text:
            "Assessment: NSTEMI with intermediate-high risk features. Pain-free since 02:00 after nitro infusion."
        },
        %{
          tag: :plan,
          text:
            "Plan: Continue dual antiplatelet therapy (aspirin + ticagrelor), initiate metoprolol tartrate 25 mg BID."
        },
        %{
          tag: :plan,
          text:
            "Schedule left heart cath this afternoon, obtain consent, maintain NPO status except meds."
        },
        %{
          tag: :plan,
          text:
            "Monitor troponin trend q6h until down-trending twice. Maintain telemetry, watch for arrhythmias."
        },
        %{
          tag: :education,
          text: "Patient counseled on symptoms requiring escalation, agrees with plan."
        }
      ]
    }
  ]

  def samples, do: @samples
end
