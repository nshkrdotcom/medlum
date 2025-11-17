# **A Comprehensive Report on HIPAA Compliance for Generative AI in a Hybrid Cloud Architecture**

## **Executive Summary**

This report provides an exhaustive technical and regulatory analysis for implementing a Generative AI (GenAI) system that processes Protected Health Information (PHI) in a hybrid deployment model. The analysis confirms that a compliant solution is technically feasible but necessitates a "compliance-first" architecture that prioritizes regulatory adherence and robust security controls over simple speed to deployment.

The primary compliance risk identified is not the AI technology itself, but the widespread, unmonitored use of non-compliant public tools by staff—a phenomenon known as "Shadow AI".1 Furthermore, the common misconception that a "HIPAA-eligible" cloud service is automatically "HIPAA-compliant" leads to critical misconfigurations that represent the single greatest vector for data breaches.3

This project's technical and regulatory justification is significantly strengthened by the January 2025 Notice of Proposed Rulemaking (NPRM) for the HIPAA Security Rule.4 This pending update eliminates the "addressable" safe harbor for key controls, making technical safeguards such as end-to-end encryption 5 and, critically, network segmentation 4 mandatory. The hybrid architecture detailed in this report is a direct and necessary implementation of these new, stricter federal standards.

The only viable architectural model is a hybrid deployment that physically and logically segments the organization's raw PHI (data-at-rest) from the cloud-based AI inference services (data-in-use). This model requires an on-premise (or private cloud) ingestion pipeline to de-identify and "embed" PHI, which is then stored in a BAA-covered vector database. All communication with cloud-based Large Language Model (LLM) services must occur over secure, private network connections such as AWS PrivateLink 6 or Azure ExpressRoute 7, ensuring no PHI-bearing data ever traverses the public internet.

A phased, 12-month implementation is recommended, beginning with a high-impact, high-visibility use case (e.g., clinical note summarization).8 This initial phase will serve to migrate clinical staff off high-risk "Shadow AI" tools and onto the new, governed, and secure internal platform. This entire initiative must be managed under a formal AI-specific governance framework, such as the HITRUST AI Risk Management Framework (AI RMF), to address risks beyond HIPAA, including model safety, bias, and clinical efficacy.10

## **Section 1: The 2025 AI-Ready HIPAA Compliance Landscape**

The introduction of Generative AI into clinical workflows creates novel regulatory challenges that are not explicitly covered by existing 2013-era HIPAA guidance. However, a combination of new proposed rules and the application of foundational HIPAA principles to new technologies (like vector databases) provides a clear, if stringent, path to compliance.

### **1.1 The End of "Addressable": The 2025 HIPAA Security Rule Mandate**

The regulatory landscape for health data security is undergoing its most significant change in over a decade. The Department of Health and Human Services (HHS), through the Office for Civil Rights (OCR), published a Notice of Proposed Rulemaking (NPRM) on January 6, 2025, to update the HIPAA Security Rule.4 This update, prompted by a massive increase in healthcare cyberattacks, directly impacts the design of any new IT system handling ePHI.4

The single most consequential change is the *elimination of the distinction between "required" and "addressable" implementation specifications*.5 For years, "addressable" controls allowed organizations to conduct a risk analysis and document why a specific safeguard was not "reasonable and appropriate," often deferring implementation. This flexibility is being removed. If the rule is finalized as proposed, all implementation specifications will be mandatory, with only very limited, specific exceptions.11

This change elevates several key technical controls from "a good idea" to "a legal mandate," all of which are foundational to the proposed hybrid AI architecture:

1. **Mandatory Encryption:** Encryption of ePHI *at rest* and *in transit*, previously an "addressable" control, is now explicitly "required".5 This makes the implementation of robust, auditable encryption for all data stores (EHRs, vector databases) and all network traffic (internal and external) non-negotiable.  
2. **Mandatory Multi-Factor Authentication (MFA):** The proposed rule will require MFA for access to all technology assets within an organization's electronic information systems.5  
3. **Mandatory Network Segmentation:** The NPRM proposes an entirely *new* implementation specification that *requires* regulated entities to "deploy technical controls to segment its relevant electronic information systems".4

The official justification provided by HHS for this new segmentation mandate directly validates the proposed hybrid architecture. HHS provides an example where an attacker compromises a point-of-sale system and then moves *laterally* to the Electronic Health Record (EHR) system on the same network.4 This is the precise risk model that a hybrid AI architecture must prevent. By segmenting the on-premise PHI repository from the cloud-connected AI application, the architecture moves from being a "best practice" to a *direct and necessary implementation of a new, mandatory HIPAA compliance control*. This provides powerful regulatory justification for the project's design and associated costs.

### **1.2 Are Vector Embeddings PHI? The Unassessed Risk**

A Retrieval-Augmented Generation (RAG) pipeline, which is the technical model for this project, functions by converting unstructured text (like a clinical note) into a mathematical representation called a "vector embedding".15 These embeddings are then stored in a specialized "vector database." A common misconception is that these embeddings, being mathematical and not human-readable, are no longer PHI.

This assumption is incorrect and dangerous. The HIPAA Privacy Rule defines PHI based on its *identifiability*, not its *form*.16 If a vector embedding can be linked back to an individual patient, or—more critically—if the original PHI can be reverse-engineered from it, it remains PHI.

Recent cybersecurity research into "embedding reconstruction" or "inversion attacks" confirms this risk. These attacks demonstrate that it is possible for an adversary with access to the embeddings to train a separate model to "invert" them, successfully reconstructing the original sensitive text.17

The logical and legal conclusion is unavoidable: **Vector embeddings derived from PHI must be classified, managed, and protected as ePHI.**

This classification has profound architectural consequences. Under HIPAA, any entity that "creates, receives, maintains, or transmits" ePHI on behalf of a covered entity is defined as a "Business Associate".22 Because the RAG pipeline *creates* ePHI (embeddings), *transmits* them to a database, and *maintains* them for retrieval, the vector database itself—whether it is an on-premise system or a cloud-based service—becomes a core component of the HIPAA-compliant boundary. It must be covered by a Business Associate Agreement (BAA) if vended, it must support mandatory encryption at rest 23, and it must be capable of generating immutable, six-year audit logs.24 This dramatically narrows the list of viable vendor solutions, as detailed in Section 4.3.

### **1.3 HIPAA's "Minimum Necessary" Principle in the Age of RAG**

A foundational tenet of the HIPAA Privacy Rule is the "Minimum Necessary" standard. This standard requires that covered entities "make reasonable efforts to limit the use or disclosure of, and requests for, protected health information to the minimum necessary to accomplish the intended purpose".25 While disclosures for the purpose of *treatment* are explicitly exempt from this standard 26, all other uses—including billing, operations, and research—are not.

A "naive" RAG pipeline is the functional antithesis of this principle. It works by "augmenting" a user's prompt, which often involves retrieving *all* documents that meet a similarity threshold—for example, all nursing notes from the last 72 hours—and "stuffing" them wholesale into the LLM's context window to answer a simple question.28 This constitutes a massive, unnecessary, and non-compliant *over-disclosure* of PHI to the LLM (a Business Associate) to accomplish a task.

The solution is to design the RAG system as an automated compliance engine. The system's design *is* the new "policy and procedure" for enforcing the Minimum Necessary standard.

1. **Prompt Engineering:** The base prompt for the AI model must establish its role, task, and explicit guardrails (e.g., "You are a billing assistant. You must *only* discuss billing codes. You must *never* discuss clinical diagnoses or patient history.").29  
2. **Retrieval Engineering:** The RAG *retriever* (the component that fetches data from the vector database) must be engineered to be the gatekeeper for "minimum necessary." It must not be a simple search tool.

This transforms the RAG retriever from a technical component into a critical, automated compliance control. It must be context-aware, integrating with an access control system (see Section 5.1). When a user (e.g., a "biller") asks a question, the retriever must not just find relevant data. It must first determine *what data this user is allowed to see for this task*. It must be programmed to retrieve *only* the specific text snippets required to answer the query, not the entire patient file, thereby technically enforcing the Minimum Necessary standard on every query.

## **Section 2: Generative AI Platform Due Diligence: BAA Coverage and Critical Service Exclusions**

The selection of a cloud and LLM provider is the single most important technical decision for this project. It is governed not by model performance alone, but by the legal and technical fine print of the provider's Business Associate Agreement (BAA) and their data-handling policies.

### **2.1 The BAA as a Prerequisite: The Shared Responsibility Model**

Using *any* third-party cloud service, vendor, or application to "create, receive, maintain, or transmit" ePHI without a signed BAA is a direct, foundational, and severe HIPAA violation.22 The BAA is a legally binding contract that establishes the vendor as a "Business Associate" and requires them to implement the same security and privacy safeguards as the covered entity.

However, the most common and dangerous pitfall in healthcare IT is misunderstanding what a BAA provides. A vendor's service being "HIPAA-eligible" (e.g., AWS S3, Azure Blob Storage, Azure OpenAI) does *not* mean that an application built on it is "HIPAA-compliant".3 This distinction is known as the **Shared Responsibility Model**.

* **Vendor's Responsibility (Security *of* the Cloud):** The cloud provider (e.g., Microsoft, AWS) signs the BAA to attest that *their* underlying infrastructure is compliant. This includes physical data center security, hardware disposal, network infrastructure, and the security *of* their managed services.30  
* **Customer's Responsibility (Security *in* the Cloud):** The customer (your organization) is 100% responsible for *configuring* those services in a compliant manner.3

This customer responsibility is where compliance universally fails. Cloud misconfigurations are the leading cause of data breaches, far exceeding sophisticated hacks.33 A developer, mistakenly believing a "HIPAA-eligible" service is inherently "safe," might deploy a database with a public IP address, forget to enable encryption-at-rest, use weak authentication, or fail to configure audit logging.33 This *misconfiguration*, not a failure of the cloud provider, is the reportable breach and the HIPAA violation. The BAA is merely the "ticket to the game"; the *real* compliance work lies in the secure architecture, configuration, and auditing, which is the customer's sole responsibility.

### **2.2 Vendor Compliance Analysis: BAA Scope and Critical Exclusions**

Not all BAAs are created equal. The definition of "Covered Services" and—more importantly—the *exclusions* are critical. Many new, state-of-the-art AI features are in "preview" or are "stateful" by design, and are often *explicitly excluded* from BAA and zero-data-retention policies.

* **Microsoft Azure OpenAI Service:**  
  * **BAA & Data Policy:** Microsoft will sign a BAA that covers Azure AI Services.31 The data privacy guarantees for Azure OpenAI are the strongest in the market: an organization's prompts (inputs), completions (outputs), embeddings, and training data are *NOT* available to other customers, *NOT* available to OpenAI, and *NOT* used by OpenAI or Microsoft to improve their models.35 Microsoft hosts the models in its own environment, and they do *not* interact with OpenAI's public API services (e.g., ChatGPT).35  
  * **CRITICAL EXCLUSIONS:** The HIPAA BAA for Azure AI services is **text-only**. It *explicitly does not* cover image inputs.36 This is a major finding: the Azure OpenAI service *cannot* be used for this project's "imaging data" requirement. Furthermore, any features in "Preview" are not covered by the standard Data Protection Addendum (DPA) and its privacy guarantees.38  
* **Amazon Web Services (AWS) Bedrock:**  
  * **BAA & Data Policy:** AWS Bedrock is a HIPAA-eligible service.6 Its data policy is a key architectural advantage: customer data is *not* shared with third-party model providers (e.g., Anthropic, Cohere, AI21 Labs) and is *not* used to improve their base models.6 When fine-tuning a model, it is done on a *private copy* of that model.6  
  * **CRITICAL EXCLUSIONS:** No specific *services* are excluded, but compliance is 100% dependent on customer configuration. The architecture *must* use AWS Key Management Service (KMS) for encryption 6, AWS Identity and Access Management (IAM) for access control, AWS CloudTrail for auditing, and AWS PrivateLink for private network connectivity.6  
  * **Implication:** AWS Bedrock is an excellent choice for a hybrid model, as it provides a single, compliant BAA wrapper for a wide varietyV of models (including Anthropic's Claude), all while guaranteeing data isolation from those model providers.  
* **Google Cloud Platform (GCP) Vertex AI:**  
  * **BAA & Data Policy:** "Generative AI on Vertex AI" is explicitly listed as a HIPAA-covered service under Google's BAA.41 Google's BAA applies to its entire infrastructure, not a separate, siloed "HIPAA cloud".41  
  * **CRITICAL EXCLUSIONS:** The BAA *does not cover* any services or features that are not "Generally Available" (GA).42 This means any "beta" or "preview" GenAI features *cannot* be used with PHI. This requires careful governance, as many cutting-edge features are released in preview.  
* **Direct API: OpenAI:**  
  * **BAA & Data Policy:** OpenAI *will* sign a BAA for its API services.43  
  * **CRITICAL EXCLUSIONS & REQUIREMENTS:**  
    1. **No ChatGPT:** The BAA *never* covers any version of the ChatGPT web interface or mobile app (Free, Plus, Pro, or Team).43 Using these with PHI is a direct violation.  
    2. **Zero Data Retention (ZDR):** The BAA is contingent on the API account being configured for Zero Data Retention.44 The standard 30-day retention policy (for abuse monitoring) is *not* HIPAA-compliant.45  
    3. **Stateful APIs NOT Covered:** This is the most critical exclusion. New, powerful APIs like the **Assistants API** and **Threads API** are "stateful" by design—their purpose is to store conversation history and files. As such, they *do not* fall under the ZDR policy and **cannot be used in a HIPAA-compliant manner**, even with a BAA.46 This makes the direct OpenAI API a poor choice for a stateful RAG application.  
* **Direct API: Anthropic (Claude):**  
  * **BAA & Data Policy:** Anthropic offers a BAA for its API products.47  
  * **CRITICAL EXCLUSIONS:** The BAA *only* covers the API, *not* the Claude.ai web interface.49 Crucially, the BAA *explicitly excludes* features like the **web search function, batch processing, and files uploaded via the Files API**.47 The exclusion of the Files API makes it almost impossible to use for a document-heavy RAG pipeline.  
  * **Implication:** The easiest, most compliant, and most functional way to use Anthropic's Claude models is *through* a BAA-covered aggregator like AWS Bedrock, which provides its own data isolation guarantees.48

### **Table 2.1: LLM Platform HIPAA Compliance Matrix**

| Platform | BAA Available? | BAA Scope / Data Policy | Critical Service/Feature Exclusions (Not HIPAA Compliant) | Data Retention Policy (for PHI) | Private Connectivity Option |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Azure OpenAI Service** | Yes 31 | BAA Covered. Data is *not* sent to OpenAI. 35 | Image Inputs (e.g., DALL-E) 36 All Preview Features 38 | Zero Retention (by default for BAA) | Azure Private Endpoint 50 |
| **AWS Bedrock** | Yes 6 | BAA Covered. Data is *not* sent to 3rd-party model providers (e.g., Anthropic). 6 | Dependent on customer configuration. Compliance is 100% the customer's responsibility. 32 | Zero Retention (by default) | AWS PrivateLink 6 |
| **GCP Vertex AI** | Yes 41 | BAA Covered. 41 | All Beta / Preview Features 42 | Zero Retention (by default) | Google Private Access |
| **OpenAI (Direct API)** | Yes 43 | BAA is contingent on enabling Zero Data Retention (ZDR). 44 | All ChatGPT products 44 Assistants API 46 Threads API 46 | Must be configured for ZDR. Standard 30-day retention is *not* compliant. 45 | AWS PrivateLink / Azure Private Link |
| **Anthropic (Direct API)** | Yes 47 | BAA Covers API only. | Claude.ai (web) 49 Files API 47 Web Search Function 47 | Zero Retention (by default) | AWS PrivateLink 48 |

## **Section 3: The Hybrid Ingestion Pipeline: De-Identifying Multi-Modal Health Data**

To enable a hybrid architecture, a secure ingestion pipeline must be built *within the organization's private, secure environment* (i.e., on-premise or in a private, non-internet-facing VPC). This pipeline's sole purpose is to process and de-identify the multi-modal PHI *before* it is ever used by the RAG system.

### **3.1 De-Identifying Unstructured Notes (Clinical, Nursing, Hospital)**

Unstructured clinical notes are the highest-risk data source. The ingestion pipeline must use a robust Natural Language Processing (NLP) model to identify and neutralize PHI.

* **Technical Architecture:**  
  1. **Extract:** Data is extracted from the source EHR database.  
  2. **Identify:** The text is processed by a Named Entity Recognition (NER) model that has been specifically trained to identify PHI entities (names, dates, locations, MRNs, etc.).51  
  3. **Redact/Tokenize:** The identified PHI is removed. Simple redaction (e.g., replacing text with "") is an option, but it destroys the semantic utility of the data for the LLM. A superior method is **pseudonymization**, which replaces the identifier with a consistent, non-identifying token (e.g., "James Smith" becomes "Patient-12345").52 This preserves the text's structure and relationships, allowing the LLM to understand that "Patient-12345" is a single entity.  
* **Model Selection:** It is critical *not* to use a generic, off-the-shelf NER model. A model pre-trained on general text (e.g., news articles) will not recognize the specific nuances of clinical language. The pipeline must use a model pre-trained on clinical text, such as **ClinicalBERT**.53 These models have demonstrated superior performance in identifying PHI within clinical narratives compared to generic BERT.53 These models can be fine-tuned on an organization's local data 55 to achieve the highest possible sensitivity.

When evaluating these models, the most important metric is **sensitivity** (also known as "recall"), not F1-score or precision.57 The system's goal is to find the *proportion of true identifiers that are correctly annotated*.57 A "false negative"—failing to detect a single piece of PHI—results in a data breach being propagated into the vector database. The system must be tuned for near-100% sensitivity, even at the cost of more "false positives" (i.e., redacting a non-PHI word that looks like a name).

### **3.2 De-Identifying Imaging Data (DICOM): A Dual-Channel Approach**

The "imaging data" requirement presents a significant technical challenge. A DICOM file is a complex object containing two distinct sources of PHI: (1) structured metadata in the file's header, and (2) unstructured PHI "burned into" the image pixels themselves.58 A compliant ingestion pipeline must address both.

* **Architecture: Dual-Channel Pipeline:**  
  1. **Channel 1: Metadata De-Identification:** This is the straightforward channel. The DICOM standard has explicit, well-defined tags for PHI (e.g., Patient Name, Patient ID, Dates).60 The pipeline must parse the DICOM header and strip, scrub, or pseudonymize these specific metadata fields.60 This process should be applied to 100% of images.  
  2. **Channel 2: Burned-In PHI Redaction:** This is a complex, computationally-intensive process.  
     * **Step A (Filter):** Do *not* run Optical Character Recognition (OCR) on every image. A large clinical study can include hundreds of thousands of images, and running OCR on all of them is financially and computationally prohibitive, taking "days to weeks".59 Instead, use a filtering model to identify a *targeted subset* of images with a high likelihood of containing burned-in text.59 This filter can be built by analyzing DICOM attributes (e.g., "Modality" or "Image Type") that are known to correlate with text-heavy images (like ultrasound summary screens).59 This targeted approach can reduce the OCR workload to as little as 1.5% of the total dataset.59  
     * **Step B (Extract):** On this *targeted subset* only, run a robust OCR engine (e.g., EasyOCR 58, Amazon Textract 63) to extract all text from the pixels.  
     * **Step C (Identify):** Feed the extracted text from Step B into the same clinical NER model used in Section 3.1 (e.g., ClinicalBERT).58  
     * **Step D (Redact):** If the NER model detects PHI, the system must use the OCR-provided coordinates to redact the PHI, typically by "blacking out" those pixels in the image.60

This dual-channel, targeted-OCR approach is the only method that balances the need for 100% metadata compliance with the performance and cost required to process the pixel-level data at scale.

### **3.3 De-Identifying Structured/Semi-Structured Data (Lab Values)**

Structured data like "lab values" (e.g., PatientID, LabName, Value, Date) is often linked with "quasi-identifiers" (e.g., ZipCode, Age, Gender). An attacker can combine these quasi-identifiers to re-identify an individual, even without a name. HIPAA provides two methods for de-identifying this data.

* Method 1: HIPAA Safe Harbor (The "Blunt" Tool):  
  This method is a simple checklist. It requires the removal of all 18 specified identifiers.52 This includes names, all geographic subdivisions smaller than a state (city, zip code), all date elements except for the year, and all ages over 89.65  
  * **Problem:** This method, while simple to audit, *destroys* the data's utility. An LLM cannot reason about a patient's clinical progress if all admission/discharge dates are removed. It cannot analyze population health trends if all zip codes are removed. Data that is "perfectly anonymous" is often "perfectly useless".66  
* Method 2: Expert Determination (The "Smart" Tool):  
  This is the preferred method for creating high-utility research and AI datasets.65 This method does not require removing all 18 identifiers. Instead, a qualified statistical expert attests in writing that the risk of re-identification from the dataset is "very small".64  
  * **Technical Implementation:** This attestation is achieved by applying statistical privacy techniques to the quasi-identifiers 67:  
    1. **k-anonymity:** This principle ensures that any single record in the dataset is indistinguishable from at least 'k-1' other records based on its set of quasi-identifiers.68 For example, the dataset is modified (e.g., by generalizing "Age 43" to "Age 40-45") so that any combination of \[Age, Gender, Zip\] appears at least 'k' times.  
    2. **l-diversity:** This is a critical extension of k-anonymity.69 It protects against homogeneity attacks. For example, if a k-anonymous group of 10 people all have the *same* sensitive attribute (e.g., "Disease: HIV"), the attacker knows every person in that group has HIV, even if they don't know *which* person. L-diversity ensures that every k-anonymous group has at least 'l' *distinct* values for the sensitive attribute.68

For this project to succeed, the ingestion pipeline for structured data *must* use the Expert Determination method. An LLM-based RAG system is only as smart as its data; it requires rich, contextual data to be effective. Safe Harbor will render the data useless, while Expert Determination (via k-anonymity and l-diversity) will preserve its utility while maintaining compliance.

## **Section 4: Reference Architecture for a Hybrid, Secure RAG System**

This section details the reference architecture that integrates the on-premise de-identification pipeline (Section 3\) with the BAA-covered cloud AI services (Section 2\) in a secure, segmented, and auditable manner.

### **4.1 Core Principle: Zero Trust in a Multi-VPC, Hub-and-Spoke Model**

The architecture's design must be rooted in a **Zero Trust** security model, which assumes no user or component is inherently trusted.30 A common and effective way to implement this in the cloud is with a **Hub-and-Spoke** network topology.72 This model uses multiple, isolated Virtual Private Clouds (VPCs) to segment and contain different workloads.73

As established in Section 1.1, this design is a *direct implementation* of the new mandatory "network segmentation" requirement in the 2025 HIPAA Security Rule proposal.4

* **Proposed Architecture:**  
  1. **On-Premise Data Center (or "Core VPC"):** This is the existing, "fire-gapped" environment that houses the source of truth: the EHR database, the DICOM archives, and all raw PHI. It should not be directly accessible from the internet.  
  2. **"Hub" VPC (Connectivity):** This VPC manages all secure connectivity. It contains the cloud-side of a dedicated connection (e.g., AWS Direct Connect, Azure ExpressRoute) and network gateways (e.g., AWS Transit Gateway 72) that route traffic between the spokes and on-premise.  
  3. **"Spoke 1" \- Ingestion VPC:** A fully isolated, private VPC. Its *only* job is to run the de-identification pipelines from Section 3\. It is the *only* cloud component given limited, read-only access to the on-premise data center. It has no other connectivity.  
  4. **"Spoke 2" \- Vector DB VPC:** A highly-secured, private-only VPC that "maintains" the ePHI (the vector embeddings and de-identified text) generated by the Ingestion VPC. Access to this database is its *only* function.  
  5. **"Spoke 3" \- Application VPC:** This VPC hosts the user-facing application, the RAG orchestration logic (which queries the Vector DB VPC), and the secure private endpoint to the cloud LLM service. This is where all user access is authenticated and logged.

### **4.2 The Secure Bridge: Enabling Hybrid Cloud with Private Endpoints**

A critical flaw in this design would be allowing the Application VPC (Spoke 3\) to call the public, internet-facing API endpoint for the LLM service. Even with a BAA and TLS encryption, this sends ePHI over the public internet, which is an unnecessary risk and a likely finding in an audit.

The solution is to use **Private Endpoints**. This technology creates a network interface with a private IP address *inside your private VPC* that connects directly to the cloud service (e.g., Bedrock, Azure OpenAI) using the provider's private, internal backbone.7

* **Architecture for AWS:** The solution uses **AWS PrivateLink**.6 The Application VPC makes an API call to an *internal VPC IP address* (e.g., 10.1.1.50), which PrivateLink routes securely and privately to Amazon Bedrock.75 All traffic stays off the public internet.74  
* **Architecture for Azure:** The solution uses **Azure Private Endpoint**.7 This places a network interface from your VNet with a private IP. The critical component is **Azure Private DNS**, which is configured to resolve the *public* hostname (e.g., my-project.openai.azure.com) to this *new internal private IP address*.50 This ensures all application code can remain unchanged while all traffic is automatically and securely routed through the private endpoint.

This private connectivity is a mandatory technical control for a high-security, HIPAA-compliant hybrid architecture.

### **4.3 The Vector Database: Selecting a HIPAA-Compliant Data Store**

As established in Section 1.2, the vector database is a PHI repository and must meet the same BAA and security standards as any other. The choice of vendor and deployment model is critical.

* **Vendor Analysis (HIPAA-Specific):**  
  1. **Pinecone:** Confirms it is HIPAA-compliant and *will* sign a BAA.78 It supports all necessary security features, including SOC2/ISO27001 certification 78, private endpoints 81, and dedicated "pods" for tenant isolation.  
  2. **Weaviate:** The Weaviate Enterprise Cloud is explicitly HIPAA-compliant on AWS (with Azure and GCP on the roadmap).82 It offers dedicated, isolated tenants 85 and end-to-end encryption.86  
  3. **Qdrant:** Confirms it is SOC2 and HIPAA certified.87 Qdrant's standout feature for this hybrid query is **Qdrant Hybrid Cloud**.89 This model allows the fully managed database to be deployed *directly within the customer's own cloud environment* (e.g., your "Spoke 2" VPC), providing the benefits of a managed service with the complete data isolation and control of a self-hosted solution.89  
  4. **DataStax Astra DB:** Built on Apache Cassandra, it is a mature, scalable database that supports HIPAA compliance 90 and VPC peering.92

For this hybrid, segmented architecture, a deployment model that offers dedicated, single-tenant isolation (like Weaviate Dedicated Cloud 85) or a hybrid-cloud deployment (like Qdrant Hybrid Cloud 89) is architecturally superior to a standard multi-tenant PaaS, as it provides the highest possible level of network segmentation and control.

### **Table 4.1: Vector Database HIPAA-Compliance Features**

| Vendor | BAA Offered? | Encryption At Rest | Customer-Managed Keys (CMEK) Support? | Private Endpoint Support? | Hybrid / Dedicated Deployment Option? |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Pinecone** | Yes 80 | Yes (AES-256) 81 | Yes 81 | Yes (Private Endpoints) 81 | Yes (Dedicated Pods) |
| **Weaviate** | Yes 82 | Yes (AES-256) 86 | Yes 82 | Yes (VPC Peering) | Yes (Dedicated Cloud) 85 |
| **Qdrant** | Yes 87 | Yes (AES-256) | Yes (Enterprise) | Yes | **Yes (Hybrid Cloud)** 89 |
| **Astra DB** | Yes 90 | Yes (AES-256) 92 | Yes | Yes (VPC Peering) 92 | Yes (Dedicated) |

### **4.4 Encryption and Key Management: Mandatory Technical Controls**

The 2025 HIPAA Security Rule proposal *mandates* encryption.5 This architecture must implement it at every layer, and control must remain with the organization, not the vendor.

1. **Customer-Managed Encryption Keys (CMEK):** The organization must not rely on provider-managed encryption keys. It must use a CMEK strategy.93 With CMEK, the cloud service (e.g., the vector database, the storage account) must call *out* to the organization's *own* key management service (e.g., Azure Key Vault Managed HSM 95, Google Cloud HSM 94) to get permission to encrypt or decrypt data.  
2. **FIPS 140-2 Compliance:** These keys must be generated, stored, and managed in a Hardware Security Module (HSM) that is **FIPS 140-2 Level 3 validated**.95 This is the federal standard for cryptographic modules and is a requirement for high-compliance environments.  
3. **Crypto-shredding:** The primary benefit of CMEK is that the organization retains ultimate control. If a security incident occurs, or if data must be deleted, the organization can simply revoke or destroy the key. This action, known as "crypto-shredding," instantly renders all data encrypted with that key permanently unreadable and unrecoverable.93

### **4.5 Case Study in Practice: Stanford's "Secure GPT" & "ChatEHR"**

This proposed hybrid architecture is not theoretical. Stanford Medicine has successfully built and deployed a functional, HIPAA-compliant generative AI system based on this exact model.98

An analysis of Stanford's architecture reveals the "gold standard" implementation 98:

1. **Cloud Service:** They use a **dedicated Azure OpenAI instance**, which is covered by their existing BAA with Microsoft.98  
2. **Hybrid Connectivity:** They connect their on-premise network directly to the Azure cloud using **Azure ExpressRoute**.98 This is a dedicated, private, high-speed fiber link, not a VPN. It guarantees that *no data ever travels over the public internet*.98  
3. **Security:** The system is a "closed system" where data is not retained by the model.98 All API keys and secrets are stored in a secure (HashiCorp) vault.98  
4. **The RAG Application:** "ChatEHR" is the custom-built RAG application that sits *on top* of this secure infrastructure. It allows clinicians to "chat" with the EMR to summarize charts, ask questions, and retrieve data.99

The Stanford model is a perfect, real-world validation of the hybrid architecture. It confirms that the "dedicated cloud instance \+ BAA \+ private network connectivity" model is the secure, compliant, and functional path forward.

## **Section 5: AI Governance and Operational Security Framework**

Building a compliant system is only the first step. HIPAA compliance is an ongoing process, not a one-time project. A robust governance and operational security framework must be established to *maintain* compliance.

### **5.1 Access Control: Implementing Granular, Context-Aware Permissions**

Traditional Role-Based Access Control (RBAC) is insufficient for a complex healthcare environment.101 RBAC is too static; a "Doctor" role and a "Biller" role may both need permission to "view" a patient record, but the "Minimum Necessary" principle dictates they must not see the *same parts* of that record.

The solution is **Attribute-Based Access Control (ABAC)**. ABAC is a far more granular, flexible, and context-aware model.102 It creates dynamic access rules based on *attributes* of the user (e.g., Role: "Biller," Department: "Oncology"), attributes of the resource (e.g., Data-Type: "BillingCode," Sensitivity: "High"), and attributes of the environment (e.g., Time: "Business Hours," Location: "Hospital-Network").

This ABAC policy engine is the technical component that *enforces* the "Minimum Necessary" principle (from Sec 1.3) within the RAG pipeline. Before the RAG retriever can fetch data, it must make a real-time call to the ABAC engine:

* **Query:** "User 'bob' (Role: 'Biller') is asking a question that requires access to 'Resource.DataType \= ClinicalNotes'. Is this allowed?"  
* **ABAC Policy:** Deny IF User.Role \= 'Biller' AND Resource.DataType \= 'ClinicalNotes'.  
* **Response:** "DENY."

The RAG application, receiving this "Deny" response, will then instruct the LLM to respond, "I am sorry, as a billing assistant, I cannot access clinical note details." This integration of ABAC is what keeps the RAG pipeline compliant on a query-by-query basis.

### **5.2 Mandatory Procedures: "Break-Glass" and Emergency Access**

The HIPAA Security Rule *requires* all covered entities to have "documented instructions and operational practices for obtaining access to necessary ePHI during an emergency situation".105

The standard solution is a **"Break-Glass" (BTG) procedure**. This is *not* for convenience (e.g., a forgotten password) but for true clinical emergencies where a delay in access could impair patient care.106

The BTG system relies on a set of pre-staged, high-privilege emergency accounts.106 Its implementation must include three key controls:

1. **Obvious Indication:** Access must be via a mechanism that provides a clear, auditable deterrent, such as a "virtual" glass to break or a sealed envelope for a password.106  
2. **Mandatory Logging:** Upon logging in, the user *must* be forced to select a reason code (e.g., "Direct Patient Care," "Billing," "Unspecified") and provide a free-text justification.108  
3. **Post-Incident Review:** Use of a BTG account must trigger an *immediate, high-priority alert* to the security and compliance teams for a manual review of the user's actions.107

### **5.3 The 6-Year Mandate: Configuring Audit Logs for the Entire RAG Pipeline**

HIPAA requires that all documentation, including audit logs, be retained for a **minimum of six years** from their creation date.24 These logs must be comprehensive, immutable (un-changeable), and track all actions related to ePHI, including *who, what, when, and where*.24

This 6-year retention rule must be applied to the *entire automated RAG pipeline*. In the event of an investigation, an auditor *will* demand a full, traceable log of all ePHI access, regardless of whether a human or an AI system performed the access.

A compliant RAG architecture *must* therefore generate and securely store a log chain for six years that details the *entire* query lifecycle. An example of a single query's log entries would be:

1. User 'jsmith' (Role: 'Doctor') submitted prompt (PromptID: 'abc-123'): 'Summarize last 24h for patient 45678'.  
2. RAG Retriever (running as 'jsmith') queried Vector DB for 'patient 45678' chunks.  
3. RAG Retriever accessed ePHI chunks: 'doc\_id\_456-chunk-3', 'doc\_id\_457-chunk-1', 'doc\_id\_789-chunk-5'.  
4. RAG Orchestrator sent augmented prompt (PromptID: 'abc-123') to LLM endpoint 'azure-privatelink-gpt4-prod'.  
5. LLM endpoint returned response (ResponseID: 'xyz-789') to orchestrator.  
6. Output Validator scanned ResponseID 'xyz-789' for leaks. (Result: 'PASS').  
7. User 'jsmith' was presented with ResponseID 'xyz-789'.

This detailed, auditable chain is the *only* way to prove compliance in a post-incident investigation.111

### **5.4 Incident Response: A Plan for PHI Leakage from LLM Outputs**

The **HIPAA Breach Notification Rule** mandates that if a breach of *unsecured* PHI occurs, the organization must notify all affected individuals "without unreasonable delay" and in no case later than **60 calendar days** after the "date of discovery".114

With Generative AI, a new, significant risk emerges: **response-side leakage**.119 This is not an attacker *stealing* data, but the LLM *itself* leaking PHI. The most likely scenario is "data collision" or "context leakage" 121:

* A doctor asks, "Summarize Patient A's status."  
* The RAG system retrieves notes for Patient A, but also an unrelated note for Patient B that was semantically similar.  
* The LLM, in a "hallucination," generates a summary of Patient A's status but includes a factual, sensitive sentence about *Patient B's* diagnosis.  
* This is a *direct, reportable breach* of Patient B's PHI *to* the user (a doctor, but one who may not be treating Patient B).

The organization's Incident Response (IR) plan must be updated to account for this AI-specific scenario.

1. **Prevention (Output Validation):** The application layer *must not* blindly trust the LLM's response. It must include an "output validator" that scans the LLM's generated text *before* displaying it to the user. This validator checks for PHI patterns (names, MRNs, etc.) that *do not* belong to the patient currently in context.121  
2. **Detection & Logging:** If the output validator detects a potential leak, it must *block* the response from being shown to the user (e.g., "An error occurred. Please rephrase your query.") and *immediately* log the full incident (prompt, context, and offending response) to a high-priority, "break-glass" security queue.121  
3. **Response:** This log *is* the "date of discovery." The compliance/security team must review this flagged incident to determine if it was a true breach. If yes, the 60-day notification clock begins.115

### **5.5 Adopting Formal AI Risk Frameworks (Beyond HIPAA)**

HIPAA is the *legal minimum* standard for protecting patient *privacy*. It is not a comprehensive framework for managing *AI risk*. HIPAA has no provisions for addressing algorithmic bias, fairness, explainability, or clinical safety—for example, an LLM "hallucinating" and recommending an incorrect drug dosage.123

To manage these new risks, the organization must adopt a formal AI risk management framework.

1. Framework 1 (General): NIST AI Risk Management Framework (AI RMF)  
   This is the U.S. national standard for managing AI risks, released in January 2023.126 It is voluntary but represents the industry best practice. It provides a core structure for AI governance: GOVERN (establish governance), MAP (identify risks), MEASURE (assess and track risks), and MANAGE (mitigate risks).129  
2. Framework 2 (Healthcare-Specific): HITRUST AI Risk Management Framework  
   This is the ideal framework for a healthcare organization.10 Its primary power is that it is not a standalone framework. It maps the abstract controls from the NIST AI RMF and international standards (like ISO/IEC 23894\) directly into the HITRUST CSF (Common Security Framework).132

An organization already using HITRUST CSF to manage its HIPAA compliance 134 can adopt the HITRUST AI RMF to *integrate* AI risk management *into its existing compliance program*. This avoids creating redundant, parallel governance structures and allows the organization to use a single, "harmonized" framework 134 to manage both its HIPAA compliance *and* its AI-specific risks (like safety, bias, and transparency).133

## **Section 6: 12-Month Implementation Roadmap and Workforce Readiness**

This final section provides an actionable, phased plan for deployment, focusing on mitigating the most immediate human risks and ensuring a sustainable, compliant, and value-driven rollout.

### **6.1 Addressing the "Shadow AI" Epidemic: From Risk to Governed Innovation**

The single greatest AI-related compliance risk facing the organization *today* is "Shadow AI".1 This is the unsanctioned, unmonitored use of public AI tools (like ChatGPT, Copilot) by employees who are simply trying to be more efficient.2

* **The Data:** Recent research is alarming. One survey found 95% of healthcare organizations report that employees with PHI access are *already using AI tools* in their workflow (e.g., in email). Despite this, one in four of these organizations *have not formally approved any AI use at all*.1 75% of IT leaders believe their employees *mistakenly* assume that tools like Microsoft Copilot are automatically HIPAA compliant.1  
* **The Risk:** An employee, trying to summarize their notes, pastes a patient's clinical history into the public ChatGPT web interface.136 This action is a *direct, unlogged, and un-auditable* HIPAA violation.137 That PHI is now in the possession of a third party (OpenAI) without a BAA and may be used to train their public models.137 This "Shadow AI" usage, which bypasses all BAA and security requirements, is a primary driver of data breaches and exposes the organization to millions in potential fines.3

This project must be framed as the *antidote to Shadow AI*. Banning all AI is not a viable solution; staff will simply use it anyway. This project builds a *secure, compliant, and useful* internal alternative, (e.g., Stanford's "Secure GPT" 100). The primary business case for this project should be **risk mitigation**. Its immediate goal is to *migrate* users *off* of high-risk, non-compliant public tools and *onto* this new, governed, and secure internal platform.

### **6.2 Workforce Readiness: Updating HIPAA Training for AI-Specific Risks**

The HIPAA Security Rule *requires* a "security awareness and training program for all members of its workforce".138 Standard, "check-the-box" annual HIPAA training is dangerously insufficient as it does not address the novel risks of Generative AI.

The organization's mandatory annual training *must* be updated with new, AI-specific modules.141 This training must include:

1. **What is "Shadow AI"?** An explanation of the risks.1  
2. **Explicit Prohibition:** A clear, unambiguous policy stating: "You *must not* use public AI tools (ChatGPT, Claude.ai, Gemini, etc.) with *any* patient or organizational data. Doing so is a HIPAA violation and grounds for disciplinary action.".136  
3. **Introduction to the *Approved* Tool:** "We are launching a secure, internal AI tool. Here is what it is, how to access it, and what it is approved for."  
4. **Secure Prompt Engineering:** "How to ask questions in a 'Minimum Necessary' way to get the best results without over-exposing data."  
5. **Reporting AI Errors:** "How to spot and report an AI 'hallucination,' error, or potential PHI leak." A voluntary, confidential reporting channel for AI safety incidents is a best practice.144

This new training is a critical administrative safeguard and the first line of defense against the "human element" of AI risk.

### **6.3 A Phased 12-Month Implementation Roadmap**

A "big-bang" deployment of a system this complex is guaranteed to fail. A phased, 12-to-18-month rollout is the industry standard.8 The strategy should be to start with 2-5 high-impact, low-risk use cases to build momentum and refine the system.8

* **Phase 1: Governance & Vendor Selection (Months 1-3)**  
  * **Action:** Establish the interdisciplinary AI Governance Committee (with clinical, legal, compliance, and IT stakeholders).125  
  * **Action:** Formally adopt the HITRUST AI Risk Management Framework.10  
  * **Action:** Finalize selection of Cloud Provider (e.g., AWS, Azure), LLM Service (e.g., Bedrock, Azure OpenAI), and Vector Database (e.g., Qdrant, Weaviate).  
  * **Action:** Execute all required Business Associate Agreements.22  
  * **Deliverable:** Define Pilot Use Case 1 (e.g., "Clinical note summarization for physicians in Internal Medicine").147  
* **Phase 2: Architecture & Ingestion Pilot (Months 4-6)**  
  * **Action:** Build the hybrid cloud architecture (multi-VPC hub-and-spoke) from Section 4.1.  
  * **Action:** Establish and test the secure private network connectivity (e.g., PrivateLink, ExpressRoute) from Section 4.2.  
  * **Action:** Build, test, and validate the *text-only* de-identification pipeline (Section 3.1).  
  * **Action:** Deploy the Vector Database in its secure, isolated, and encrypted spoke VPC.148  
  * **Deliverable:** A functional, end-to-end "smoke test" of the text-only RAG pipeline using de-identified data.  
* **Phase 3: Multi-Modal Expansion & Validation (Months 7-9)**  
  * **Action:** Build, test, and integrate the complex ingestion pipelines for DICOM (Section 3.2) and Lab Values (Section 3.3).  
  * **Action:** Conduct a formal Security Risk Analysis (SRA), including third-party penetration testing of the entire system.149  
  * **Action:** Conduct a formal NIST/HITRUST AI risk assessment (bias, fairness, safety) for Pilot Use Case 1\.10  
  * **Action:** Develop and finalize the AI-specific mandatory workforce training modules (Section 6.2).  
  * **Deliverable:** A production-ready, validated, multi-modal RAG system.  
* **Phase 4: Phased Clinical Rollout & Audit (Months 10-12)**  
  * **Action:** Deploy Pilot Use Case 1 to the initial, single pilot group (e.g., Internal Medicine department).9  
  * **Action:** Conduct mandatory, in-person AI/HIPAA training for this pilot group *before* they are given access.142  
  * **Action:** Begin the first 12-month compliance audit, as required by the 2025 NPRM.11  
  * **Action:** Activate the confidential, voluntary AI safety incident reporting channel.144  
  * **Deliverable:** A live, governed, and monitored AI service, generating user feedback and KPIs (e.g., adoption rates, reduction in "Shadow AI" tool usage) to inform the next phase of the rollout.9

## **Conclusions and Recommendations**

The analysis concludes that a HIPAA-compliant Generative AI RAG pipeline is not only technically feasible but is also a strategic necessity for mitigating the significant, unaddressed compliance risks of "Shadow AI." The project's success is contingent on rejecting a "move fast" mentality and adopting a "compliance-by-design" architectural philosophy.

The core regulatory and technical risks are clear and manageable:

1. **Vendor Risk:** The *only* compliant LLM services are those from BAA-covered vendors (e.g., Azure OpenAI, AWS Bedrock) that guarantee zero data retention and no model training on PHI. Critically, stateful or preview APIs (like the OpenAI Assistants API) and non-text modalities (like Azure's image inputs) are *not* covered and must be prohibited.  
2. **Architectural Risk:** The *only* compliant deployment is a hybrid model. The 2025 HIPAA Security Rule update effectively mandates this by requiring network segmentation. All PHI and ePHI (including vector embeddings) must be processed and stored in a private, segmented on-premise or VPC environment, with all cloud AI service calls routed exclusively over private connections like AWS PrivateLink or Azure ExpressRoute.  
3. **Human Risk:** The *greatest* immediate risk is "Shadow AI." This project's primary strategic value is as a risk-reduction initiative to migrate staff from high-risk public tools to this new, secure, and governed internal platform. This must be reinforced with new, AI-specific mandatory HIPAA training.

**Final Recommendations:**

1. **Prioritize the 2025 Security Rule:** The project team must proceed as if the January 2025 NPRM is already law. All design decisions must be based on the new *mandatory* requirements for network segmentation, end-to-end encryption (with CMEK), and MFA.  
2. **Adopt the HITRUST AI RMF:** The AI Governance Committee must immediately adopt the HITRUST AI Risk Management Framework. This will integrate AI safety and bias governance *into* the existing HIPAA compliance program, preventing redundant work and ensuring a holistic approach.  
3. **Select Vendors Based on Exclusions:** The choice of cloud provider must be made with a full understanding of their BAA *exclusions*. For this multi-modal query, AWS Bedrock presents the most flexible BAA, as it covers multiple model providers (like Anthropic) and does not have the "text-only" limitation of Azure OpenAI.  
4. **Execute the 12-Month Phased Rollout:** The project must begin with the 12-month plan outlined in Section 6.3. The first phase—establishing governance, signing BAAs, and building the secure PrivateLink/ExpressRoute architecture—must be completed before any PHI is processed.

#### **Works cited**

1. Shadow AI Is Outpacing Healthcare Security, New Paubox Report ..., accessed November 14, 2025, [https://www.morningstar.com/news/business-wire/20251014137455/shadow-ai-is-outpacing-healthcare-security-new-paubox-report-warns](https://www.morningstar.com/news/business-wire/20251014137455/shadow-ai-is-outpacing-healthcare-security-new-paubox-report-warns)  
2. AI Governance and Control in the Healthcare Industry \- Harmonic Security, accessed November 14, 2025, [https://www.harmonic.security/blog-posts/ai-governance-and-control-in-the-healthcare-industry](https://www.harmonic.security/blog-posts/ai-governance-and-control-in-the-healthcare-industry)  
3. HIPAA Compliance AI: Guide to Using LLMs Safely in Healthcare \- TechMagic, accessed November 14, 2025, [https://www.techmagic.co/blog/hipaa-compliant-llms](https://www.techmagic.co/blog/hipaa-compliant-llms)  
4. HIPAA Security Rule To Strengthen the ... \- Federal Register, accessed November 14, 2025, [https://www.federalregister.gov/documents/2025/01/06/2024-30983/hipaa-security-rule-to-strengthen-the-cybersecurity-of-electronic-protected-health-information](https://www.federalregister.gov/documents/2025/01/06/2024-30983/hipaa-security-rule-to-strengthen-the-cybersecurity-of-electronic-protected-health-information)  
5. OCR Proposes Major Changes to the HIPAA Security Rule ..., accessed November 14, 2025, [https://www.arnoldporter.com/en/perspectives/advisories/2025/01/ocr-proposes-major-changes-to-hipaa-security-rule](https://www.arnoldporter.com/en/perspectives/advisories/2025/01/ocr-proposes-major-changes-to-hipaa-security-rule)  
6. Secure Gen AI Apps \- Amazon Bedrock Security and Privacy \- AWS, accessed November 14, 2025, [https://aws.amazon.com/bedrock/security-compliance/](https://aws.amazon.com/bedrock/security-compliance/)  
7. Connecting OpenAI Private Endpoints Across VNETs \- Microsoft Learn, accessed November 14, 2025, [https://learn.microsoft.com/en-us/shows/azure-essentials-show/connecting-openai-private-endpoints-across-vnets](https://learn.microsoft.com/en-us/shows/azure-essentials-show/connecting-openai-private-endpoints-across-vnets)  
8. How to Develop an AI Implementation Roadmap in 2025? \- Biz4Group LLC, accessed November 14, 2025, [https://www.biz4group.com/blog/develop-ai-implementation-roadmap](https://www.biz4group.com/blog/develop-ai-implementation-roadmap)  
9. How to Implement AI Voice Agents in Healthcare (2025 Guide) \- Retell AI, accessed November 14, 2025, [https://www.retellai.com/blog/ai-voice-agent-healthcare-implementation-guide](https://www.retellai.com/blog/ai-voice-agent-healthcare-implementation-guide)  
10. AI Risk Management Assessment and Insights \- HITRUST Alliance, accessed November 14, 2025, [https://hitrustalliance.net/assessments-and-certifications/airiskmanagementassessment](https://hitrustalliance.net/assessments-and-certifications/airiskmanagementassessment)  
11. HIPAA Security Rule Notice of Proposed Rulemaking to Strengthen Cybersecurity for Electronic Protected Health Information | HHS.gov, accessed November 14, 2025, [https://www.hhs.gov/hipaa/for-professionals/security/hipaa-security-rule-nprm/factsheet/index.html](https://www.hhs.gov/hipaa/for-professionals/security/hipaa-security-rule-nprm/factsheet/index.html)  
12. What 2025 HIPAA Changes Mean to You \- Thales, accessed November 14, 2025, [https://cpl.thalesgroup.com/blog/data-security/what-2025-hipaa-changes-mean-to-you](https://cpl.thalesgroup.com/blog/data-security/what-2025-hipaa-changes-mean-to-you)  
13. Changes Proposed by HHS to Strengthen HIPAA Security Rule \- Maynard Nexsen, accessed November 14, 2025, [https://www.maynardnexsen.com/publication-changes-proposed-by-hhs-to-strengthen-hipaa-security-rule](https://www.maynardnexsen.com/publication-changes-proposed-by-hhs-to-strengthen-hipaa-security-rule)  
14. Proposed HIPAA Security Rule Updates May Significantly Impact Covered Entities and Business Associates | Epstein Becker Green, accessed November 14, 2025, [https://www.ebglaw.com/insights/publications/proposed-hipaa-security-rule-updates-may-significantly-impact-covered-entities-and-business-associates](https://www.ebglaw.com/insights/publications/proposed-hipaa-security-rule-updates-may-significantly-impact-covered-entities-and-business-associates)  
15. Synthesizing healthcare data for AI model training, with HIPAA Expert Determination, accessed November 14, 2025, [https://www.tonic.ai/guides/hipaa-ai-compliance](https://www.tonic.ai/guides/hipaa-ai-compliance)  
16. What is Considered PHI under HIPAA? Updated for 2025 \- The HIPAA Journal, accessed November 14, 2025, [https://www.hipaajournal.com/considered-phi-hipaa/](https://www.hipaajournal.com/considered-phi-hipaa/)  
17. \[2511.07481\] Comparing Reconstruction Attacks on Pretrained Versus Full Fine-tuned Large Language Model Embeddings on Homo Sapiens Splice Sites Genomic Data \- arXiv, accessed November 14, 2025, [https://arxiv.org/abs/2511.07481](https://arxiv.org/abs/2511.07481)  
18. Reconstruction Attacks on Machine Unlearning: Simple Models are Vulnerable \- arXiv, accessed November 14, 2025, [https://arxiv.org/html/2405.20272v1](https://arxiv.org/html/2405.20272v1)  
19. Text Embedding Inversion Security for Multilingual Language Models \- arXiv, accessed November 14, 2025, [https://arxiv.org/html/2401.12192v4](https://arxiv.org/html/2401.12192v4)  
20. Rethinking the Privacy of Text Embeddings: A Reproducibility Study of “Text Embeddings Reveal (Almost) As Much As Text” \- arXiv, accessed November 14, 2025, [https://arxiv.org/html/2507.07700v1](https://arxiv.org/html/2507.07700v1)  
21. Mitigating Privacy Risks in LLM Embeddings from Embedding Inversion \- arXiv, accessed November 14, 2025, [https://arxiv.org/html/2411.05034v1](https://arxiv.org/html/2411.05034v1)  
22. What Covered Entities Should Know About Cloud Computing and HIPAA Compliance, accessed November 14, 2025, [https://www.hipaajournal.com/cloud-computing-hipaa-compliance/](https://www.hipaajournal.com/cloud-computing-hipaa-compliance/)  
23. HIPAA Encryption Requirements \- 2025 Update, accessed November 14, 2025, [https://www.hipaajournal.com/hipaa-encryption-requirements/](https://www.hipaajournal.com/hipaa-encryption-requirements/)  
24. Retention Policies for Cloud Audit Logs: What to Know \- Censinet, accessed November 14, 2025, [https://www.censinet.com/perspectives/retention-policies-for-cloud-audit-logs-what-to-know](https://www.censinet.com/perspectives/retention-policies-for-cloud-audit-logs-what-to-know)  
25. Minimum Necessary Requirement \- HHS.gov, accessed November 14, 2025, [https://www.hhs.gov/hipaa/for-professionals/privacy/guidance/minimum-necessary-requirement/index.html](https://www.hhs.gov/hipaa/for-professionals/privacy/guidance/minimum-necessary-requirement/index.html)  
26. Minimum Necessary \- HHS.gov, accessed November 14, 2025, [https://www.hhs.gov/hipaa/for-professionals/faq/minimum-necessary/index.html](https://www.hhs.gov/hipaa/for-professionals/faq/minimum-necessary/index.html)  
27. The HIPAA Minimum Necessary Rule Standard \- Updated for 2025, accessed November 14, 2025, [https://www.hipaajournal.com/ahima-hipaa-minimum-necessary-standard-3481/](https://www.hipaajournal.com/ahima-hipaa-minimum-necessary-standard-3481/)  
28. A Guide to Generative AI Security in Healthcare | NeuralTrust, accessed November 14, 2025, [https://neuraltrust.ai/blog/gen-ai-security-healthcare](https://neuraltrust.ai/blog/gen-ai-security-healthcare)  
29. Context Engineering for AI Agents: When to Use RAG vs. Prompt \- Regal.ai, accessed November 14, 2025, [https://www.regal.ai/blog/context-engineering-for-ai-agents](https://www.regal.ai/blog/context-engineering-for-ai-agents)  
30. HIPAA compliance for generative AI solutions on AWS, accessed November 14, 2025, [https://aws.amazon.com/blogs/industries/hipaa-compliance-for-generative-ai-solutions-on-aws/](https://aws.amazon.com/blogs/industries/hipaa-compliance-for-generative-ai-solutions-on-aws/)  
31. HIPAA \- Azure Compliance | Microsoft Learn, accessed November 14, 2025, [https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-hipaa-us](https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-hipaa-us)  
32. AWS Bedrock HIPAA BAA: What's Covered, What's Not \- SCIMUS, accessed November 14, 2025, [https://thescimus.com/blog/aws-bedrock-hipaa-baa-whats-covered-whats-not/](https://thescimus.com/blog/aws-bedrock-hipaa-baa-whats-covered-whats-not/)  
33. The Most Common Cloud Misconfigurations That Could Lead to Security Breaches, accessed November 14, 2025, [https://www.trendmicro.com/vinfo/us/security/news/virtualization-and-cloud/the-most-common-cloud-misconfigurations-that-could-lead-to-security-breaches](https://www.trendmicro.com/vinfo/us/security/news/virtualization-and-cloud/the-most-common-cloud-misconfigurations-that-could-lead-to-security-breaches)  
34. Master HIPAA Compliance in Multi-Cloud Setups | Challenges & Practical Fixes in 2025, accessed November 14, 2025, [https://www.trustcloud.ai/grc/hipaa-compliance-in-multi-cloud-environments-challenges-and-solutions/](https://www.trustcloud.ai/grc/hipaa-compliance-in-multi-cloud-environments-challenges-and-solutions/)  
35. Data, privacy, and security for Azure Direct Models in Azure AI Foundry \- Microsoft Learn, accessed November 14, 2025, [https://learn.microsoft.com/en-us/azure/ai-foundry/responsible-ai/openai/data-privacy](https://learn.microsoft.com/en-us/azure/ai-foundry/responsible-ai/openai/data-privacy)  
36. Azure AI BAA/HIPAA Compliance \- Microsoft Q\&A, accessed November 14, 2025, [https://learn.microsoft.com/en-us/answers/questions/2265200/azure-ai-baa-hipaa-compliance](https://learn.microsoft.com/en-us/answers/questions/2265200/azure-ai-baa-hipaa-compliance)  
37. Azure OpenAI Hipaa Compliance Status \- Microsoft Q\&A, accessed November 14, 2025, [https://learn.microsoft.com/en-us/answers/questions/2106637/azure-openai-hipaa-compliance-status](https://learn.microsoft.com/en-us/answers/questions/2106637/azure-openai-hipaa-compliance-status)  
38. Does Azure OpenAI fall under the DPA \- Microsoft Learn, accessed November 14, 2025, [https://learn.microsoft.com/en-us/answers/questions/1361952/does-azure-openai-fall-under-the-dpa](https://learn.microsoft.com/en-us/answers/questions/1361952/does-azure-openai-fall-under-the-dpa)  
39. HIPAA Compliance \- Amazon Web Services (AWS), accessed November 14, 2025, [https://aws.amazon.com/compliance/hipaa-compliance/](https://aws.amazon.com/compliance/hipaa-compliance/)  
40. Is there any documentation on how AWS Bedrock can be HIPAA eligible in more detail?, accessed November 14, 2025, [https://repost.aws/questions/QUN1xYL4ihQ6ybeYjH6a8Ogg/is-there-any-documentation-on-how-aws-bedrock-can-be-hipaa-eligible-in-more-detail](https://repost.aws/questions/QUN1xYL4ihQ6ybeYjH6a8Ogg/is-there-any-documentation-on-how-aws-bedrock-can-be-hipaa-eligible-in-more-detail)  
41. HIPAA Compliance on Google Cloud | GCP Security, accessed November 14, 2025, [https://cloud.google.com/security/compliance/hipaa](https://cloud.google.com/security/compliance/hipaa)  
42. New Hipaa Website For SecOps Services | Google Cloud, accessed November 14, 2025, [https://cloud.google.com/terms/secops/hipaacoveredservices](https://cloud.google.com/terms/secops/hipaacoveredservices)  
43. How can I get a Business Associate Agreement (BAA) with OpenAI ..., accessed November 14, 2025, [https://help.openai.com/en/articles/8660679-how-can-i-get-a-business-associate-agreement-baa-with-openai](https://help.openai.com/en/articles/8660679-how-can-i-get-a-business-associate-agreement-baa-with-openai)  
44. Is OpenAI HIPAA Compliant? 2025 Guide \- Arkenea, accessed November 14, 2025, [https://arkenea.com/blog/is-openai-hipaa-compliant-2025-guide/](https://arkenea.com/blog/is-openai-hipaa-compliant-2025-guide/)  
45. Data controls in the OpenAI platform, accessed November 14, 2025, [https://platform.openai.com/docs/guides/your-data](https://platform.openai.com/docs/guides/your-data)  
46. HIPAA Compliance for Assistants, Threads, etc. Timeline \- OpenAI Developer Community, accessed November 14, 2025, [https://community.openai.com/t/hipaa-compliance-for-assistants-threads-etc-timeline/583002](https://community.openai.com/t/hipaa-compliance-for-assistants-threads-etc-timeline/583002)  
47. Business Associate Agreements (BAA) for Commercial Customers ..., accessed November 14, 2025, [https://support.claude.com/en/articles/8114513-business-associate-agreements-baa-for-commercial-customers](https://support.claude.com/en/articles/8114513-business-associate-agreements-baa-for-commercial-customers)  
48. Claude for healthcare \- making HIPAA compliance work without enterprise budgets, accessed November 14, 2025, [https://amitkoth.com/claude-healthcare-hipaa-compliance/](https://amitkoth.com/claude-healthcare-hipaa-compliance/)  
49. Is Claude AI HIPAA compliant? \- Paubox, accessed November 14, 2025, [https://www.paubox.com/blog/is-claude-ai-hipaa-compliant](https://www.paubox.com/blog/is-claude-ai-hipaa-compliant)  
50. Network and access configuration for Azure OpenAI On Your Data \- Microsoft Learn, accessed November 14, 2025, [https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/on-your-data-configuration](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/on-your-data-configuration)  
51. Using word embeddings to improve the privacy of clinical notes \- Oxford Academic, accessed November 14, 2025, [https://academic.oup.com/jamia/article/27/6/901/5835527](https://academic.oup.com/jamia/article/27/6/901/5835527)  
52. Modes of De-identification \- Lister Hill National Center for Biomedical Communications, accessed November 14, 2025, [https://lhncbc.nlm.nih.gov/LHC-publications/PDF/pub9526.pdf](https://lhncbc.nlm.nih.gov/LHC-publications/PDF/pub9526.pdf)  
53. DeIDClinic: A Multi-Layered Framework for De-identification of Clinical Free-text Data \- arXiv, accessed November 14, 2025, [https://arxiv.org/html/2410.01648v1](https://arxiv.org/html/2410.01648v1)  
54. Tranformer Models for Clinical Text De-identification \- arXiv, accessed November 14, 2025, [https://arxiv.org/pdf/2204.07056](https://arxiv.org/pdf/2204.07056)  
55. Data-Constrained Synthesis of Training Data for De-Identification \- arXiv, accessed November 14, 2025, [https://arxiv.org/html/2502.14677v1](https://arxiv.org/html/2502.14677v1)  
56. Distilling Large Language Models for Efficient Clinical Information Extraction \- arXiv, accessed November 14, 2025, [https://arxiv.org/html/2501.00031v1](https://arxiv.org/html/2501.00031v1)  
57. Deidentification of free-text medical records using pre-trained bidirectional transformers, accessed November 14, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC8330601/](https://pmc.ncbi.nlm.nih.gov/articles/PMC8330601/)  
58. De-identifying Medical Images Cost-Effectively with Vision Language Models on Databricks, accessed November 14, 2025, [https://www.databricks.com/blog/de-identifying-medical-images-cost-effectively-vision-language-models-databricks](https://www.databricks.com/blog/de-identifying-medical-images-cost-effectively-vision-language-models-databricks)  
59. A Method for Efficient De-identification of DICOM Metadata and Burned-in Pixel Text \- NIH, accessed November 14, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC11522224/](https://pmc.ncbi.nlm.nih.gov/articles/PMC11522224/)  
60. AI and De-Identification for Medical Imaging within CRDC \- Cancer Research Data Commons, accessed November 14, 2025, [https://datacommons.cancer.gov/media/255](https://datacommons.cancer.gov/media/255)  
61. Deep classification algorithm for De-identification of DICOM medical images \- arXiv, accessed November 14, 2025, [https://www.arxiv.org/abs/2508.02177](https://www.arxiv.org/abs/2508.02177)  
62. A Method for Efficient De-identification of DICOM Metadata and Burned-in Pixel Text., accessed November 14, 2025, [https://scholars.duke.edu/individual/pub1623309](https://scholars.duke.edu/individual/pub1623309)  
63. Accelerating Clinical Imaging Intelligence with HIPAA-Compliant AI Solutions | Caylent, accessed November 14, 2025, [https://caylent.com/blog/accelerating-clinical-imaging-intelligence-with-hipaa-compliant-ai-solutions](https://caylent.com/blog/accelerating-clinical-imaging-intelligence-with-hipaa-compliant-ai-solutions)  
64. De-identification of Protected Health Information: 2025 Update \- The HIPAA Journal, accessed November 14, 2025, [https://www.hipaajournal.com/de-identification-protected-health-information/](https://www.hipaajournal.com/de-identification-protected-health-information/)  
65. Methods for De-identification of PHI | HHS.gov, accessed November 14, 2025, [https://www.hhs.gov/hipaa/for-professionals/special-topics/de-identification/index.html](https://www.hhs.gov/hipaa/for-professionals/special-topics/de-identification/index.html)  
66. Guidelines and Methods for De-Identifying Protected Health Information \- Institute for Families in Society \- University of South Carolina, accessed November 14, 2025, [https://ifs.sc.edu/resources/documents/USC\_IFS\_PHIDataDeIdentification\_18\_REV22.pdf](https://ifs.sc.edu/resources/documents/USC_IFS_PHIDataDeIdentification_18_REV22.pdf)  
67. K-anonymity, l-diversity and t-closeness | Data Privacy Handbook \- GitHub Pages, accessed November 14, 2025, [https://utrechtuniversity.github.io/dataprivacyhandbook/k-l-t-anonymity.html](https://utrechtuniversity.github.io/dataprivacyhandbook/k-l-t-anonymity.html)  
68. The L Diversity Data Anonymization Model: Extending K Anonymity \- K2view, accessed November 14, 2025, [https://www.k2view.com/blog/l-diversity/](https://www.k2view.com/blog/l-diversity/)  
69. t-Closeness: Privacy Beyond k-Anonymity and \-Diversity \- CS@Purdue, accessed November 14, 2025, [https://www.cs.purdue.edu/homes/ninghui/papers/t\_closeness\_icde07.pdf](https://www.cs.purdue.edu/homes/ninghui/papers/t_closeness_icde07.pdf)  
70. Attribute Utility Motivated k-anonymization of Datasets to Support the Heterogeneous Needs of Biomedical Researchers \- NIH, accessed November 14, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC3243250/](https://pmc.ncbi.nlm.nih.gov/articles/PMC3243250/)  
71. Computing l-diversity for a dataset | Sensitive Data Protection | Google Cloud Documentation, accessed November 14, 2025, [https://docs.cloud.google.com/sensitive-data-protection/docs/compute-l-diversity](https://docs.cloud.google.com/sensitive-data-protection/docs/compute-l-diversity)  
72. Scale generative AI use cases, Part 1: Multi-tenant hub and spoke architecture using AWS Transit Gateway | Artificial Intelligence, accessed November 14, 2025, [https://aws.amazon.com/blogs/machine-learning/scale-generative-ai-use-cases-part-1-multi-tenant-hub-and-spoke-architecture-using-aws-transit-gateway/](https://aws.amazon.com/blogs/machine-learning/scale-generative-ai-use-cases-part-1-multi-tenant-hub-and-spoke-architecture-using-aws-transit-gateway/)  
73. Building a Scalable and Secure Multi-VPC AWS Network Infrastructure, accessed November 14, 2025, [https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/welcome.html](https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/welcome.html)  
74. Private network for data movement in generative AI \- Amazon AWS, accessed November 14, 2025, [https://aws.amazon.com/blogs/networking-and-content-delivery/private-network-for-data-movement-in-generative-ai/](https://aws.amazon.com/blogs/networking-and-content-delivery/private-network-for-data-movement-in-generative-ai/)  
75. Use AWS PrivateLink to set up private access to Amazon Bedrock ..., accessed November 14, 2025, [https://aws.amazon.com/blogs/machine-learning/use-aws-privatelink-to-set-up-private-access-to-amazon-bedrock/](https://aws.amazon.com/blogs/machine-learning/use-aws-privatelink-to-set-up-private-access-to-amazon-bedrock/)  
76. Security best practices to consider while fine-tuning models in Amazon Bedrock, accessed November 14, 2025, [https://aws.amazon.com/blogs/machine-learning/security-best-practices-to-consider-while-fine-tuning-models-in-amazon-bedrock/](https://aws.amazon.com/blogs/machine-learning/security-best-practices-to-consider-while-fine-tuning-models-in-amazon-bedrock/)  
77. Securing Azure OpenAI inside a virtual network with private endpoints \- Microsoft Learn, accessed November 14, 2025, [https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/network](https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/network)  
78. Pinecone: The vector database to build knowledgeable AI, accessed November 14, 2025, [https://www.pinecone.io/](https://www.pinecone.io/)  
79. Is Pinecone HIPAA compliant? \- Paubox, accessed November 14, 2025, [https://www.paubox.com/blog/is-pinecone-hipaa-compliant](https://www.paubox.com/blog/is-pinecone-hipaa-compliant)  
80. Pinecone is now HIPAA compliant, accessed November 14, 2025, [https://www.pinecone.io/blog/hipaa/](https://www.pinecone.io/blog/hipaa/)  
81. Trust and Security \- Pinecone, accessed November 14, 2025, [https://www.pinecone.io/security/](https://www.pinecone.io/security/)  
82. Secure AI for Healthcare: HIPAA-compliant vector search with Weaviate, accessed November 14, 2025, [https://weaviate.io/blog/weaviate-hipaa-compliant](https://weaviate.io/blog/weaviate-hipaa-compliant)  
83. HIPAA-Compliant Vector Search, RAG Advancements, and Cross-Device Integration, accessed November 14, 2025, [https://newsletter.weaviate.io/p/hipaa-compliant-vector-search-rag-advancements-and-cross-device-integration](https://newsletter.weaviate.io/p/hipaa-compliant-vector-search-rag-advancements-and-cross-device-integration)  
84. 6 posts tagged with "announcement" \- Weaviate, accessed November 14, 2025, [https://weaviate.io/blog/tags/announcement](https://weaviate.io/blog/tags/announcement)  
85. Dedicated Cloud Vector Database \- Weaviate, accessed November 14, 2025, [https://weaviate.io/deployment/dedicated](https://weaviate.io/deployment/dedicated)  
86. Security | Weaviate, accessed November 14, 2025, [https://weaviate.io/security](https://weaviate.io/security)  
87. Qdrant Cloud Security, accessed November 14, 2025, [https://qdrant.tech/documentation/cloud-security/](https://qdrant.tech/documentation/cloud-security/)  
88. Enterprise Search Solutions for Your Business \- Qdrant, accessed November 14, 2025, [https://qdrant.tech/enterprise-solutions/](https://qdrant.tech/enterprise-solutions/)  
89. STACKIT and Qdrant Hybrid Cloud for Best Data Privacy, accessed November 14, 2025, [https://qdrant.tech/blog/hybrid-cloud-stackit/](https://qdrant.tech/blog/hybrid-cloud-stackit/)  
90. DataStax Astra DB \- Microsoft Marketplace, accessed November 14, 2025, [https://marketplace.microsoft.com/en-us/marketplace/apps/datastax.datastax-astra-azure](https://marketplace.microsoft.com/en-us/marketplace/apps/datastax.datastax-astra-azure)  
91. Frequently asked questions about Astra DB Serverless | DataStax Docs, accessed November 14, 2025, [https://docs.datastax.com/en/astra-db-serverless/faqs.html](https://docs.datastax.com/en/astra-db-serverless/faqs.html)  
92. Healthcare \- DataStax, an IBM company, accessed November 14, 2025, [https://www.datastax.com/use-cases/healthcare](https://www.datastax.com/use-cases/healthcare)  
93. Customer-managed encryption keys (CMEK) \- Google Cloud Documentation, accessed November 14, 2025, [https://docs.cloud.google.com/kms/docs/cmek](https://docs.cloud.google.com/kms/docs/cmek)  
94. Encryption For Cloud Security \- Google Cloud, accessed November 14, 2025, [https://cloud.google.com/security/encryption](https://cloud.google.com/security/encryption)  
95. Manage your customer-managed encryption key \- Power Platform | Microsoft Learn, accessed November 14, 2025, [https://learn.microsoft.com/en-us/power-platform/admin/customer-managed-key](https://learn.microsoft.com/en-us/power-platform/admin/customer-managed-key)  
96. Cloud Key Management | Google Cloud, accessed November 14, 2025, [https://cloud.google.com/security/products/security-key-management](https://cloud.google.com/security/products/security-key-management)  
97. Encryption Best Practices for Protecting ePHI in the Cloud \- HIPAA Vault, accessed November 14, 2025, [https://www.hipaavault.com/resources/encryption-best-practices-hipaa-cloud/](https://www.hipaavault.com/resources/encryption-best-practices-hipaa-cloud/)  
98. Development of Secure Infrastructure for Advancing Generative AI ..., accessed November 14, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC11469521/](https://pmc.ncbi.nlm.nih.gov/articles/PMC11469521/)  
99. Clinicians can 'chat' with medical records through new AI software, ChatEHR, accessed November 14, 2025, [https://med.stanford.edu/news/all-news/2025/06/chatehr.html](https://med.stanford.edu/news/all-news/2025/06/chatehr.html)  
100. Stanford Health Care and Stanford School of Medicine Secure GPT (beta), accessed November 14, 2025, [https://securegpt.stanfordhealthcare.org/](https://securegpt.stanfordhealthcare.org/)  
101. Health Information System Role-Based Access Control Current Security Trends and Challenges \- PMC \- NIH, accessed November 14, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC5836325/](https://pmc.ncbi.nlm.nih.gov/articles/PMC5836325/)  
102. What is Attribute-Based Access Control (ABAC)? \- CrowdStrike, accessed November 14, 2025, [https://www.crowdstrike.com/en-us/cybersecurity-101/identity-protection/attribute-based-access-control-abac/](https://www.crowdstrike.com/en-us/cybersecurity-101/identity-protection/attribute-based-access-control-abac/)  
103. RBAC vs ABAC: Choosing the Right Access Control Model \- LoginRadius, accessed November 14, 2025, [https://www.loginradius.com/blog/identity/rbac-vs-abac](https://www.loginradius.com/blog/identity/rbac-vs-abac)  
104. Attribute-based Access Control: Benefits & Comparison with RBAC \- Kiteworks, accessed November 14, 2025, [https://www.kiteworks.com/risk-compliance-glossary/attribute-based-access-control/](https://www.kiteworks.com/risk-compliance-glossary/attribute-based-access-control/)  
105. Emergency Access Procedures Under the HIPAA Security Rule \- Compliancy Group, accessed November 14, 2025, [https://compliancy-group.com/emergency-access-procedures-under-the-hipaa-security-rule/](https://compliancy-group.com/emergency-access-procedures-under-the-hipaa-security-rule/)  
106. Break Glass Procedure: Granting Emergency Access to Critical ePHI Systems | Health Insurance Portability and Accountability Act \- Yale's HIPAA, accessed November 14, 2025, [https://hipaa.yale.edu/security/break-glass-procedure-granting-emergency-access-critical-ephi-systems](https://hipaa.yale.edu/security/break-glass-procedure-granting-emergency-access-critical-ephi-systems)  
107. NEMA/COCIR/JIRA Security and Privacy Committee (SPC), accessed November 14, 2025, [https://www.medicalimaging.org/wp-content/uploads/2011/02/Break-Glass\_-\_Emergency\_Access\_to\_Healthcare\_Systems.pdf](https://www.medicalimaging.org/wp-content/uploads/2011/02/Break-Glass_-_Emergency_Access_to_Healthcare_Systems.pdf)  
108. HIPAA Guidance: Epic's Break the Glass Function, accessed November 14, 2025, [https://www.cmich.edu/docs/default-source/president's-division/general-counsel/hipaa/hipaa-guidance-btg.pdf?sfvrsn=f1820735\_4](https://www.cmich.edu/docs/default-source/president's-division/general-counsel/hipaa/hipaa-guidance-btg.pdf?sfvrsn=f1820735_4)  
109. HIPAA Audit Log Requirements: A Complete Manual \- Cayosoft, accessed November 14, 2025, [https://www.cayosoft.com/blog/hipaa-audit-log-requirements/](https://www.cayosoft.com/blog/hipaa-audit-log-requirements/)  
110. Should HIPAA Audit Logs be Kept for 6 Years? \- IS Partners, LLC, accessed November 14, 2025, [https://www.ispartnersllc.com/blog/hipaa-audit-log-retention-six-years/](https://www.ispartnersllc.com/blog/hipaa-audit-log-retention-six-years/)  
111. What Are HIPAA Audit Trail and Audit Log Requirements? \- Compliancy Group, accessed November 14, 2025, [https://compliancy-group.com/hipaa-audit-log-requirements/](https://compliancy-group.com/hipaa-audit-log-requirements/)  
112. HIPAA Audit Logs: Complete Requirements for Healthcare Compliance in 2025 \- Kiteworks, accessed November 14, 2025, [https://www.kiteworks.com/hipaa-compliance/hipaa-audit-log-requirements/](https://www.kiteworks.com/hipaa-compliance/hipaa-audit-log-requirements/)  
113. HIPAA-compliant observability and security for health information systems \- Datadog, accessed November 14, 2025, [https://www.datadoghq.com/blog/hipaa-compliant-log-management/](https://www.datadoghq.com/blog/hipaa-compliant-log-management/)  
114. HIPAA Regulations: Notification in the Case of Breach \-- Timeliness of, accessed November 14, 2025, [https://www.brickergraydon.com/insights/resources/key/hipaa-regulations-notification-in-the-case-of-breach-timeliness-of-notification-164-404-b](https://www.brickergraydon.com/insights/resources/key/hipaa-regulations-notification-in-the-case-of-breach-timeliness-of-notification-164-404-b)  
115. HIPAA Breach Notification Rule | American Medical Association, accessed November 14, 2025, [https://www.ama-assn.org/practice-management/hipaa/hipaa-breach-notification-rule](https://www.ama-assn.org/practice-management/hipaa/hipaa-breach-notification-rule)  
116. 45 CFR § 164.404 \- Notification to individuals. \- Law.Cornell.Edu, accessed November 14, 2025, [https://www.law.cornell.edu/cfr/text/45/164.404](https://www.law.cornell.edu/cfr/text/45/164.404)  
117. What are the HIPAA Breach Notification Requirements? Updated 2025, accessed November 14, 2025, [https://www.hipaajournal.com/hipaa-breach-notification-requirements/](https://www.hipaajournal.com/hipaa-breach-notification-requirements/)  
118. accessed November 14, 2025, [https://www.brickergraydon.com/insights/resources/key/hipaa-regulations-notification-in-the-case-of-breach-timeliness-of-notification-164-404-b\#:\~:text=Section%2013402(d)%20of%20the,enforcement%20has%20requested%20a%20delay.](https://www.brickergraydon.com/insights/resources/key/hipaa-regulations-notification-in-the-case-of-breach-timeliness-of-notification-164-404-b#:~:text=Section%2013402\(d\)%20of%20the,enforcement%20has%20requested%20a%20delay.)  
119. Is Your LLM Leaking Sensitive Data? A Developer's Guide to Preventing Sensitive Information Disclosure \- Pangea Cloud, accessed November 14, 2025, [https://pangea.cloud/blog/a-developers-guide-to-preventing-sensitive-information-disclosure/](https://pangea.cloud/blog/a-developers-guide-to-preventing-sensitive-information-disclosure/)  
120. The 2025 Playbook For Securing Sensitive Data In LLM Applications \- Protecto AI, accessed November 14, 2025, [https://www.protecto.ai/blog/securing-sensitive-data-llm-applications/](https://www.protecto.ai/blog/securing-sensitive-data-llm-applications/)  
121. The Builder's Notes: Why HIPAA Compliance Breaks Every LLM Implementation \- Medium, accessed November 14, 2025, [https://medium.com/illumination/the-builders-notes-why-hipaa-compliance-breaks-every-llm-implementation-282f755c8fb4](https://medium.com/illumination/the-builders-notes-why-hipaa-compliance-breaks-every-llm-implementation-282f755c8fb4)  
122. How to Secure Sensitive Data in LLM Prompts? \- Strac, accessed November 14, 2025, [https://www.strac.io/blog/secure-sensitive-data-in-llm-prompts](https://www.strac.io/blog/secure-sensitive-data-in-llm-prompts)  
123. Implementing large language models in healthcare while balancing control, collaboration, costs and security \- PubMed Central, accessed November 14, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC11885444/](https://pmc.ncbi.nlm.nih.gov/articles/PMC11885444/)  
124. Generative AI in Medical Practice: In-Depth Exploration of Privacy and Security Challenges, accessed November 14, 2025, [https://www.jmir.org/2024/1/e53008/](https://www.jmir.org/2024/1/e53008/)  
125. Developing an AI Governance Framework for Safe and Responsible ..., accessed November 14, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC12340452/](https://pmc.ncbi.nlm.nih.gov/articles/PMC12340452/)  
126. A Strategic Guide to NIST AI 100-1 Implementation \- Accorian, accessed November 14, 2025, [https://www.accorian.com/a-strategic-guide-to-nist-ai-100-1-implementation/](https://www.accorian.com/a-strategic-guide-to-nist-ai-100-1-implementation/)  
127. AI Risk Management Framework | NIST \- National Institute of Standards and Technology, accessed November 14, 2025, [https://www.nist.gov/itl/ai-risk-management-framework](https://www.nist.gov/itl/ai-risk-management-framework)  
128. Artificial Intelligence Risk Management Framework (AI RMF 1.0) | NIST, accessed November 14, 2025, [https://www.nist.gov/publications/artificial-intelligence-risk-management-framework-ai-rmf-10](https://www.nist.gov/publications/artificial-intelligence-risk-management-framework-ai-rmf-10)  
129. CISO Perspectives: A Practical Guide to Implementing the NIST AI Risk Management Framework (AI RMF) \- A-Team Chronicles, accessed November 14, 2025, [https://www.ateam-oracle.com/post/ciso-perspectives-a-practical-guide-to-implementing-the-nist-ai-risk-management-framework-ai-rmf](https://www.ateam-oracle.com/post/ciso-perspectives-a-practical-guide-to-implementing-the-nist-ai-risk-management-framework-ai-rmf)  
130. accessed November 14, 2025, [https://hitrustalliance.net/assessments-and-certifications/airiskmanagementassessment\#:\~:text=The%20HITRUST%20AI%20Risk%20Management,and%20manage%20AI%2Dspecific%20risks.](https://hitrustalliance.net/assessments-and-certifications/airiskmanagementassessment#:~:text=The%20HITRUST%20AI%20Risk%20Management,and%20manage%20AI%2Dspecific%20risks.)  
131. HITRUST Launches New AI Risk Management Assessment, accessed November 14, 2025, [https://hitrustalliance.net/press-releases/hitrust-launches-new-ai-risk-management-assessment](https://hitrustalliance.net/press-releases/hitrust-launches-new-ai-risk-management-assessment)  
132. The HITRUST AI Security Assessment: Explained \- A-LIGN, accessed November 14, 2025, [https://www.a-lign.com/articles/the-hitrust-ai-security-assessment-explained](https://www.a-lign.com/articles/the-hitrust-ai-security-assessment-explained)  
133. HITRUST AI Risk Management Program Overview \- IS Partners, LLC, accessed November 14, 2025, [https://www.ispartnersllc.com/blog/hitrust-ai-risk-management-program/](https://www.ispartnersllc.com/blog/hitrust-ai-risk-management-program/)  
134. Introducing the HITRUST AI Risk Management Assessment, accessed November 14, 2025, [https://hitrustalliance.net/blog/introducing-the-hitrust-ai-risk-management-assessment](https://hitrustalliance.net/blog/introducing-the-hitrust-ai-risk-management-assessment)  
135. Importance of Addressing Shadow AI for HIPAA Compliance, accessed November 14, 2025, [https://aihc-assn.org/importance-of-addressing-shadow-ai-for-hipaa-compliance/](https://aihc-assn.org/importance-of-addressing-shadow-ai-for-hipaa-compliance/)  
136. Using LLMs Under HIPAA: ChatGPT & Gemini \- HIPAA Vault, accessed November 14, 2025, [https://www.hipaavault.com/resources/hipaa-compliant-hosting-insights/hipaa-compliant-llm-chatgpt-gemini/](https://www.hipaavault.com/resources/hipaa-compliant-hosting-insights/hipaa-compliant-llm-chatgpt-gemini/)  
137. HIPAA, LLMs, and Data Privacy: What Every Clinician Should Know \- Twofold Health, accessed November 14, 2025, [https://www.trytwofold.com/blog/hipaa-and-data-privacy-risks-ai](https://www.trytwofold.com/blog/hipaa-and-data-privacy-risks-ai)  
138. HIPAA Training: Health Information Privacy Laws \- Traliant, accessed November 14, 2025, [https://www.traliant.com/courses/hipaa-training/](https://www.traliant.com/courses/hipaa-training/)  
139. HIPAA Training Requirements \- Updated for 2025 \- The HIPAA Journal, accessed November 14, 2025, [https://www.hipaajournal.com/hipaa-training-requirements/](https://www.hipaajournal.com/hipaa-training-requirements/)  
140. HIPAA Training and Resources \- HHS.gov, accessed November 14, 2025, [https://www.hhs.gov/hipaa/for-professionals/training/index.html](https://www.hhs.gov/hipaa/for-professionals/training/index.html)  
141. HIPAA Annual New Hire Training \- American Institute of Healthcare ..., accessed November 14, 2025, [https://aihc-assn.org/product/hipaa-annual-new-hire-training/](https://aihc-assn.org/product/hipaa-annual-new-hire-training/)  
142. HIPAA Compliance for AI in Digital Health: What Privacy Officers Need to Know, accessed November 14, 2025, [https://www.foley.com/insights/publications/2025/05/hipaa-compliance-ai-digital-health-privacy-officers-need-know/](https://www.foley.com/insights/publications/2025/05/hipaa-compliance-ai-digital-health-privacy-officers-need-know/)  
143. When AI Technology and HIPAA Collide \- The HIPAA Journal, accessed November 14, 2025, [https://www.hipaajournal.com/when-ai-technology-and-hipaa-collide/](https://www.hipaajournal.com/when-ai-technology-and-hipaa-collide/)  
144. Manatt Health: Health AI Policy Tracker, accessed November 14, 2025, [https://www.manatt.com/insights/newsletters/health-highlights/manatt-health-health-ai-policy-tracker](https://www.manatt.com/insights/newsletters/health-highlights/manatt-health-health-ai-policy-tracker)  
145. HIPAA-Compliant Agentic AI for Better Patient Care in Healthcare \- Kodexo Labs, accessed November 14, 2025, [https://kodexolabs.com/hipaa-compliant-agentic-ai-for-better-patient-care/](https://kodexolabs.com/hipaa-compliant-agentic-ai-for-better-patient-care/)  
146. Developing an AI Governance Framework for Safe and Responsible AI in Health Care Organizations: Protocol for a Multimethod Study, accessed November 14, 2025, [https://www.researchprotocols.org/2025/1/e75702](https://www.researchprotocols.org/2025/1/e75702)  
147. Generative AI in Healthcare & Life Sciences \- Amazon AWS, accessed November 14, 2025, [https://aws.amazon.com/health/gen-ai/](https://aws.amazon.com/health/gen-ai/)  
148. LLM in Healthcare Implementation: 6 Key Steps \- Scimus, accessed November 14, 2025, [https://thescimus.com/blog/llm-in-healthcare-implementation-6-key-steps/](https://thescimus.com/blog/llm-in-healthcare-implementation-6-key-steps/)  
149. Best Practices for HIPAA Compliance of LLMs \- Healthcare Cloud Blog | Cloudticity, accessed November 14, 2025, [https://blog.cloudticity.com/hipaa-compliance-llms-best-practices](https://blog.cloudticity.com/hipaa-compliance-llms-best-practices)  
150. Cigna Healthcare Unveils Industry-Leading AI-Powered Digital Tools for a Simple and Reliable Customer Experience, accessed November 14, 2025, [https://newsroom.cigna.com/cigna-healthcare-unveils-industry-leading-ai-powered-digital-tools](https://newsroom.cigna.com/cigna-healthcare-unveils-industry-leading-ai-powered-digital-tools)