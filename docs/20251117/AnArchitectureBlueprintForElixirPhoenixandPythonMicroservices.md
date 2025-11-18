# **The Polyglot Data Stack: An Architectural Blueprint for Elixir/Phoenix and Python Microservices**

## **Introduction: The Polyglot Imperative**

The development of sophisticated, large-scale data applications necessitates a "best of breed" architectural approach. No single programming language or framework excels at every task required by a modern system—from high-concurrency web servers to an ecosystem of data science tooling. The optimal architecture, therefore, is often a polyglot one, leveraging the specific strengths of different technology stacks for different functional domains.1

This report details a complete architectural blueprint for a data application centered around an Elixir/Phoenix core. The central thesis is the separation of the system into two distinct planes:

1. **The Control Plane (Elixir/Phoenix):** The core application, which serves as the central orchestrator, web-facing front end, and real-time communication hub. The Elixir ecosystem, built on the Erlang VM (BEAM/OTP), provides unparalleled "concurrency primitives" 2 and a fault-tolerant, scalable foundation for managing state, orchestrating distributed processes 3, and delivering real-time user experiences with Phoenix LiveView. This stack is optimized for scalability and maintainability.5  
2. **The Data Plane (Python):** A set of specialized, distributed microservices responsible for the "heavy lifting" of data processing. Python is the undisputed *lingua franca* of data science, machine learning, and artificial intelligence.6 It possesses a mature, extensive ecosystem of libraries for analysis, ingestion, and reporting that would be impossible to replicate.7

This symbiotic relationship leverages the best of both worlds. The challenge, and the primary focus of this report, lies in the *integration* of these two planes. A poorly designed integration will negate the benefits of both, resulting in a brittle, high-latency, and unmaintainable system. A well-designed integration, however, creates a robust, highly scalable, and future-proof application.

This report will be structured around the three functional subsystems required by the application:

1. **Ingestion:** The tools and patterns for acquiring, normalizing, and streaming data into the system.  
2. **Analysis:** The frameworks and libraries for parsing, processing, and transforming raw data into high-value insights, with a deep focus on Python-based services.  
3. **Reporting:** The platforms for visualizing and delivering these insights to both internal stakeholders and end-users.

Ultimately, this document provides a prescriptive guide to the "how"—the foundational communication patterns, the specific open-source tool recommendations for each pillar, and the high-level integration blueprints required to build a world-class polyglot data application.

## **The Architectural Foundation: Interservice Communication**

Before selecting specific tools for ingestion or analysis, the foundational communication patterns must be established. These choices—synchronous versus asynchronous, request/reply versus event log—will dictate the entire system's coupling, latency, and resilience. This is the most critical and complex part of a polyglot microservice architecture.1

### **Synchronous Communication (The "Query" Pattern): gRPC vs. REST**

For internal services that require an immediate, blocking response (e.g., "Elixir requests a Python service to validate this data *now*"), a synchronous, request/reply pattern is appropriate. The two primary choices are REST and gRPC.8

**REST (Representational State Transfer)** is a software architecture approach based on the HTTP protocol, using standard verbs (GET, POST, PUT, DELETE) to manage data.8 Its primary advantages are simplicity, human-readability (JSON), and ease of use for debugging.9 However, for high-performance internal communication, it carries significant overhead in terms of (text-based) payload size and connection management.

**gRPC (gRPC Remote Procedure Call)** is an open-source API architecture governed by the Cloud Native Computing Foundation.8 It is an implementation of the RPC model, where a client application directly calls methods on a server application.8 It is not a replacement for REST in all cases, but it is purpose-built for high-performance, polyglot microservice communication. Its advantages are:

1. **Performance:** gRPC uses HTTP/2 for data transmission, enabling multiplexing and reducing latency. It "typically outperforms REST in terms of raw throughput and latency".9  
2. **Protocol Buffers (Protobufs):** This is the most significant advantage in a polyglot system. Instead of JSON, gRPC uses Protobufs, a language-agnostic binary format, to define a "contract" or schema in a .proto file.10 This schema is used to auto-generate client and server code in multiple languages (Elixir, Python, Go, etc.).10

In a data-heavy application, the "developer experience" benefit of REST is a red herring for internal communication. The real bottleneck and primary source of errors in a polyglot environment is not the protocol's complexity but the ambiguity of data. Data-type mismatches, serialization errors, and payload validation failures between Elixir and Python 13 are a constant source of friction.

gRPC's use of a mandatory, strongly-typed Protobuf schema 11 eliminates this entire class of bugs. The binary protocol and HTTP/2 transport 8 are essential optimizations for a data-intensive backend.

**Recommendation:** Use **gRPC** for all internal, synchronous Elixir-to-Python (and Python-to-Python) service calls. The strong schema contract and high performance are non-negotiable for a robust polyglot system. Reserve REST APIs (e.g., built with Python's FastAPI 15) exclusively for *public-facing* endpoints.

### **Asynchronous Communication (The "Data" and "Task" Pattern): Apache Kafka vs. RabbitMQ**

For any operation that is long-running, resource-intensive, or can be decoupled, asynchronous communication is essential. This is the domain of message brokers, and the two dominant open-source choices are Apache Kafka and RabbitMQ.4

**Apache Kafka** is a "durable message broker system" 16 that functions as a distributed, immutable *log*.17 Its design model is that of a "dumb broker/smart consumer".17 Kafka itself does not track which messages have been read; it simply retains all messages for a configurable retention period. Consumers (the "smart" part) are responsible for managing their own position (offset) in the log.17 This design enables:

* **Extreme Throughput:** Kafka is optimized for sequential disk I/O and can "send millions of messages per second".16  
* **Data Replay:** Because messages are not deleted upon consumption, a new service can be brought online to re-process all data from the beginning of the log.  
* **Event Sourcing:** It is the *de facto* standard for event-sourcing and real-time data streaming pipelines.18

**RabbitMQ** is a "smart broker/dumb consumer" message broker.17 It provides "complex message routing" capabilities 16 using an exchange-queue topology.17 Its retention model is "acknowledgment based" 18—once a "dumb" consumer successfully processes a message and acknowledges it, the message is *removed* from the queue.17 This model is ideal for:

* **Task Queues:** Distributing units of work to a pool of consumers.  
* **Per-Message Guarantees:** Ensuring a specific task is processed, with features like message priority.19  
* **Complex Routing:** Using wildcards or headers to route messages to different queues.19

A common misconception is that these two technologies are mutually exclusive. For a mature data architecture, they are not; they serve two distinct purposes. The system described in this report has two separate asynchronous needs:

1. A high-throughput, continuous **stream of data** (e.g., user events, IoT data, logs).  
2. An orchestration system for discrete, stateful **tasks** (e.g., "analyze this specific PDF for this specific user," "generate this report").

Kafka's log-based, high-throughput model 16 is the perfect fit for the "data river" (1). RabbitMQ's smart routing and per-message guarantees 18 are the perfect fit for the "task broker" (2). While it is possible to use Kafka for task management, it is complex and often requires a "steep learning curve".19 Conversely, while RabbitMQ can handle millions of messages per second, it "requires multiple brokers to do so".16

**Recommendation:** A hybrid architecture.

1. Use **Apache Kafka** as the primary data bus for high-volume, event-driven *ingestion streams*.  
2. Use **RabbitMQ** as the inter-service *task broker* for command-and-control messages (e.g., Elixir ordering a Python worker to perform a specific, stateful job).

### **The Abstraction Layer: The Dapr Alternative**

An advanced alternative to direct broker integration is the Distributed Application Runtime (Dapr). Dapr is an open-source, portable, event-driven runtime that runs as a "sidecar" 22 alongside each service. It provides a set of abstract APIs for common distributed system concerns, including "service-to-service communication, state management, pub/sub messaging".20

In this model, the Elixir/Phoenix application would not contain a Kafka or RabbitMQ client. Instead, it would make a simple HTTP or gRPC call to its *local* Dapr sidecar's "publish" API. A separate Dapr component configuration file (written in YAML) would then tell that sidecar *which* broker (Kafka, RabbitMQ, etc.) to use.20

This approach provides the ultimate in architectural flexibility: the entire application's messaging backbone could be swapped from RabbitMQ to Kafka to a cloud-native solution *without changing a single line of application code*. Dapr is designed explicitly to simplify polyglot microservice development.22

However, this flexibility comes at the cost of an additional, complex component to manage, deploy, and observe.

**Recommendation:** For a new application, *start without* Dapr to minimize operational complexity. Build directly against the recommended hybrid Kafka/RabbitMQ stack. Keep Dapr in mind as a future-proof solution if the number of polyglot microservices and messaging backbones expands significantly, as it provides a powerful abstraction for managing this complexity.22

### **Table 1: Interservice Communication Trade-Offs**

| Technology | Communication Model | Data/Task Model | Performance (Latency/Throughput) | Coupling | Primary Use Case |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **REST API** | Synchronous | Request/Reply | High-Latency / Medium-Throughput | Tightly Coupled | Public-facing APIs, Simple internal queries |
| **gRPC** | Synchronous | Request/Reply | Low-Latency / High-Throughput | Tightly Coupled (Schema) | Internal service-to-service "query" calls |
| **Apache Kafka** | Asynchronous | Streaming Log | Very-Low-Latency / Very-High-Throughput | Loosely Coupled | High-volume "data river" for ingestion, Event Sourcing |
| **RabbitMQ** | Asynchronous | Task Queue | Low-Latency / High-Throughput | Loosely Coupled | Inter-service "task broker" for commands, Task work |

## **Pillar 1: The Data Ingestion Subsystem**

The Ingestion subsystem is responsible for acquiring data from external and internal sources and routing it to the appropriate processing or storage layer. This pillar will leverage both the Elixir core's "control plane" and the Python "data plane."

### **Elixir-Native Ingestion with Broadway**

For consuming data from the asynchronous "data river" (Apache Kafka), the Elixir-native solution is **Broadway**. Broadway is an open-source Elixir library for "build\[ing\] concurrent and multi-stage data ingestion and data processing pipelines".24

Broadway is not a simple job processor; it is a dedicated *data-processing* tool. Its core features, built upon Elixir's GenStage 24, make it ideal for this architecture:

* **Native Producers:** It has official, built-in integrations for Kafka, RabbitMQ, Amazon SQS, and Google Cloud PubSub.25  
* **Back-Pressure:** It builds on GenStage to "provide back pressure and avoid overloads, ensuring you only ingest data the system can handle".25  
* **Concurrency & Batching:** It automatically defines concurrent producers, concurrent processing, and batch handling, leading to "time and cost efficient ingestion".24

Broadway is the ideal "Elixir-native consumer" for the Kafka data river established in Section II. It is designed specifically for "continuous, long-running pipelines" 24 and "ingesting high throughout event streams".29 This allows the Elixir application to perform initial, highly-concurrent, and fault-tolerant processing (e.g., filtering, validation, simple transformation) on the raw data stream *using the BEAM's inherent strengths*. This clearly differentiates it from Elixir's *job processors* (like Oban), which are designed for discrete tasks, not continuous streams.29

**Recommendation:** Use **Broadway** within the Elixir/Phoenix application as the primary, fault-tolerant consumer of the Apache Kafka ingestion streams.

### **External ELT Platforms (Python-based)**

The application will also need to ingest data from a wide variety of third-party sources (e.g., SaaS APIs, relational databases, flat files).32 This is the domain of Extract, Load, Transform (ELT) platforms. The leading open-source contenders are Airbyte, Meltano, and dlt.32

A comparison of Airbyte and Meltano, the two market leaders, reveals a key difference in their connector ecosystems. Airbyte boasts 600+ connectors, which are "developed mostly by airbyte team and ukraininan contractors".34 This suggests a more centrally-managed, and potentially more resilient, connector library. Meltano's connectors, by contrast, are "developed by community, hobbyists and software vendors" 34, leveraging the open-source Singer.io standard.32

While both are powerful, Airbyte's PyAirbyte library 36 makes it the clear choice for a Python-centric data plane. PyAirbyte is an "open-source Python library... that enables you to build ETL pipelines effortlessly".36 This is a critical distinction. It means ingestion is not a "black box" UI-driven process. The Elixir core can send a gRPC "task" (via RabbitMQ) to a Python/FastAPI service, which then programmatically executes an Airbyte ingestion pipeline using PyAirbyte.36 This approach is far more robust, testable, and  
integrated than relying on fragile API calls to a separate, stateful ELT platform.  
**Recommendation:** Use **Airbyte** for batch-loading data from diverse third-party sources (APIs, databases, flat files 32). The integration should be programmatic, using the **PyAirbyte** library 36 from within a dedicated Python microservice.

### **Workflow Orchestration: Airflow, Dagster, and Elixir**

The system will inevitably require complex, multi-step batch workflows with inter-dependencies (e.g., "Run the Airbyte sync for Salesforce, *then* run the Python analysis model, *then* generate the PDF report, *and if that fails*, alert the ops team"). This is the domain of workflow orchestrators.

It is crucial to differentiate the *three* distinct types of "work" in this architecture:

1. **Job Processing (Oban):** Reliably executing a single, discrete, often-stateful task (e.g., "send this email").  
2. **Stream Processing (Broadway):** Handling a continuous, high-throughput, stateless stream of events (e.g., "process the Kafka topic").  
3. **Workflow Orchestration (Airflow/Dagster):** Managing the *dependencies*, *schedule*, and *retries* of a multi-step *batch* of tasks (e.g., a Directed Acyclic Graph, or DAG).

The Elixir application's native tools, Oban and Broadway, are world-class at (1) and (2).29 They are *not* designed for (3). Apache Airflow is a "Python-based platform for running directed acyclic graphs (DAGs) of tasks".37 Dagster is a more modern, "type-safe & testable pipeline development" tool.36

The Elixir/Phoenix application should not attempt to replicate this complex orchestration logic. Instead, it should leverage these mature Python-based tools. The Elixir core will act as the *trigger* for these workflows. For example, a scheduled Oban.Job (Elixir) can make a gRPC or REST API call to the Airflow (Python) service to *trigger* a DAG, but it will not manage the individual tasks *within* that DAG.

**Recommendation:** Use **Apache Airflow** 38 (for ecosystem maturity) or **Dagster** 36 (for its modern, type-safe, code-based approach) to define and orchestrate complex, multi-step *batch* data pipelines. The Elixir application will *initiate* these workflows via API calls, not manage them.

### **Table 2: Data Ingestion Platform Comparison**

| Tool | Primary Function | Connector Model | Configuration | Ideal Use Case |
| :---- | :---- | :---- | :---- | :---- |
| **Airbyte** | ELT (Batch Replication) | 600+ Connectors (Team-Managed) 34 | UI, JSON, Python (PyAirbyte) 36 | Programmatic batch data replication from 3rd-party APIs. |
| **Meltano** | ELT (Singer-based) | 600+ Connectors (Community-Managed) 34 | Code/YAML | Building custom ELT pipelines leveraging the Singer.io standard. |
| **Apache NiFi** | Data Flow Automation | 500+ Sources (Processors) 35 | Visual Flow (Graph-based) | Real-time, continuous data flow automation and routing. |
| **Broadway (Elixir)** | Stream Processing | Kafka, RabbitMQ, SQS, etc. 25 | Code (Elixir) | Elixir-native consumption of high-throughput data streams. |

## **Pillar 2: The Data Analysis Subsystem (The Python Deep Dive)**

This pillar is the heart of the "data plane." It will exist as one or more Python microservices, orchestrated by the Elixir/Phoenix "control plane." These services will be responsible for the complex, computationally-intensive, or ecosystem-dependent tasks that are a poor fit for the BEAM.

### **Service Framework: FastAPI**

The Python analysis services must be high-performance, asynchronous-capable, and easily containerized. The clear, modern choice for this is **FastAPI**.

FastAPI is a "modern, fast (high-performance), web framework... on par with NodeJS and Go".15 It is built upon two key technologies:

1. **Starlette:** For high-performance, asynchronous (async/await) capabilities.15  
2. **Pydantic:** For data validation and settings management based on standard Python type hints.15

This stack is an exact match for the architecture's needs. The async support is crucial for handling I/O-intensive tasks (like calling external APIs or reading from object storage) without blocking.41 The Pydantic integration, as will be explored, is the *key* to creating modern, reliable data extraction pipelines from unstructured text.

**Recommendation:** All Python-based analysis microservices must be built using **FastAPI**.15 They should be deployed as production-ready ASGI applications using a process manager with Gunicorn and Uvicorn workers.40

### **Analysis of Unstructured Data (PDFs & Text)**

A primary function of a data application is extracting value from unstructured sources. PDFs are notoriously difficult, a "paradox" that preserves visual fidelity for human eyes 44 but offers no "machine-readable structure".44 Many PDFs are simply "images of text" (scanned documents) 46, requiring Optical Character Recognition (OCR).

A robust Python analysis service must implement a *parsing hierarchy*, using the right tool for the right job.

Level 1: Basic Text Extraction  
For simple, text-based PDFs, speed is key.

* **pypdf:** One of the oldest and most widely used libraries, good for simple text extraction, splitting, and merging.48  
* **pypdfium2:** Known for "blazing speed" 50, providing clean, basic text extraction with no structure.

Level 2: Layout-Aware Extraction (Tables & Coordinates)  
When layout and tables are important, more advanced tools are needed.

* **pdfplumber:** Highly regarded for its ability to extract structured data. Its extract\_table() function is a common reason for its selection.48 It can also extract paragraphs and bounding boxes.48  
* **PyMuPDF (fitz):** "Lightning-fast and versatile".48 It is frequently cited as the best-in-class for performance 53 and can extract text, images, annotations, and precise coordinates.48

Level 3: Semantic Partitioning for AI/RAG  
For feeding data to Large Language Models (LLMs), raw text is suboptimal. The text must be semantically chunked.

* **unstructured.io:** This is a complete framework, not just a library.50 Its core function, partition\_pdf 55, does not just return text; it returns a list of "Element" objects 55, such as Title, NarrativeText, ListItem, or Table. This provides "clean semantic chunks, perfect for RAG workflows".50 Critically, unstructured.io integrates OCR. Its "strategy" parameter 56 can be set to "hi\_res" or "ocr\_only" to automatically process scanned documents 55 using Tesseract (a common open-source OCR engine 59). This "strategy" pattern vastly simplifies the Python service logic.

Level 4: High-Fidelity Conversion to Markdown  
For the highest-quality input to LLMs, especially from academic or complex documents, Markdown is a superior format.

* **marker-pdf:** This modern tool converts PDFs to Markdown "quickly and accurately".50 It is "optimized for books and scientific papers" 62 and excels at correctly formatting tables, code blocks, headers/footers, and even converting equations to LaTeX.62

### **Table 3: Unstructured Data Parsing Library Comparison**

| Library | Primary Use Case | Output Format | OCR Integration |
| :---- | :---- | :---- | :---- |
| **PyMuPDF (fitz)** | Speed, Raw Extraction, Image/Annotation Extraction 48 | Raw Text, Coordinates, Images | Manual (via Tesseract) 54 |
| **pdfplumber** | Structured Table Extraction 45 | Structured Text, Table Data | Built on pdfminer 52 |
| **unstructured.io** | Semantic Chunking for AI/RAG 50 | List of Element Objects 55 | Built-in via "strategies" 56 |
| **marker-pdf** | High-Fidelity Conversion (Academic) 62 | Markdown (with tables, LaTeX) 63 | N/A (focuses on text-based PDFs) |

**Recommendation (Parsing Pipeline):** The Python service should not choose one tool, but implement a multi-stage pipeline:

1. **Default Parsing:** Use **unstructured.io** with strategy="auto". This will use "fast" pdfminer logic for text-based PDFs and automatically escalate to OCR for scanned images.56  
2. **Complex/Scanned Layouts:** For documents known to be complex (e.g., multi-column, scanned invoices), explicitly call **unstructured.io** with strategy="hi\_res".55  
3. **LLM Summarization (Academic):** For text-heavy, academic documents, first convert the PDF using **marker-pdf** 62 to generate clean, LLM-friendly Markdown.

### **Extracting Structured Data from Text with LLMs**

After parsing, the Python service will have raw text. The next step is to extract structured, machine-readable data (e.g., a "ResearchPaper" object with title, List\[Author\], and List).64 This is a "holy grail" of data applications: turning "unstructured data" into "structured data".65

The key to this process is **Pydantic**. LLMs excel at data understanding, and Pydantic excels at data validation.66 The combination is revolutionary.

1. **Define the Schema:** The developer first defines the *desired* output as a Pydantic BaseModel in Python.64  
2. **Generate JSON Schema:** Pydantic models can "generate a JSON schema, which is perfect for our use case".68 This schema model\_json\_schema() 69 is a formal definition of the ResearchPaper object.  
3. **Prompt the LLM:** This JSON schema is passed to the LLM as part of the prompt, effectively "instruct\[ing\]... how to return data".65 Many modern models (like OpenAI's) have a "JSON Mode" 70 that is enabled by this.

However, "JSON Mode" and simple prompting are not foolproof. They can still produce invalid JSON, hallucinate fields, or fail validation, leading to "parsing headaches" 71 and "fragile code".71 For a production system, a more robust solution is required: **constrained generation**.

This involves libraries that hook into the LLM's generation process at a low level, *forcing* its output to conform to the schema. The leading open-source tools in this space include jsonformer 70, guidance 70, Instructor 73, and outlines.70

Of these, **outlines** is the "best of breed" choice for this architecture. Its key advantage is that it is *model-agnostic* (works with OpenAI, local Llama models via transformers, Ollama, etc.) 71 and *guarantees* valid structure.

The outlines library integrates directly with Pydantic. The developer does not pass a JSON schema string; they pass the *Pydantic class itself* as the output type.71 A call looks like this:

review \= model("Review:...", ProductReview,...) 71

outlines then "guarantees structured outputs during generation" 71 by filtering the LLM's possible tokens at every single step, ensuring the final output is always a  
ProductReview object. This eliminates the entire class of parsing and validation errors.  
**Recommendation:** On the Python/FastAPI service, use **pydantic** 66 to define data schemas. Use **outlines** 71 to constrain a local LLM (e.g., Llama 3.2 via Ollama 69) to produce *guaranteed-valid* Pydantic objects from the unstructured text.

### **Domain-Specific Analysis (Case Study: Medical)**

For specialized domains like finance or healthcare 75, generic LLMs and parsers are insufficient. The Python analysis service must be extensible to load domain-specific models.

* **scispaCy:** For clinical text, the service can load scispaCy, a "Python package containing spaCy models for processing biomedical, scientific or clinical text".76 This provides highly-optimized, pre-trained models for Named Entity Recognition (NER) (e.g., en\_ner\_bc5cdr\_md for chemicals/diseases, en\_core\_med7\_lg for clinical entities).79  
* **Hugging Face transformers:** For deeper semantic understanding, the service can load domain-specific models from Hugging Face. Examples include emilyalsentzer/Bio\_ClinicalBERT, which is pre-trained on all MIMIC III notes 81, or Simonlee711/Clinical\_ModernBERT, which is designed for long-context clinical narratives up to 8192 tokens.82

**Recommendation:** The Python analysis service should be designed as a pipeline. For specialized text (e.g., a medical record), the text should first be processed by **scispaCy** 79 for fast, reliable NER. The extracted entities and text can then be passed to a fine-tuned Hugging Face transformers model (e.g., Bio\_ClinicalBERT) 81 for summarization or classification.83

## **Pillar 3: The Data Reporting Subsystem**

The final pillar is responsible for surfacing the value generated by the analysis subsystem. This includes both internal Business Intelligence (BI) dashboards for the team and programmatic, user-facing reports (both in-app and as documents).

### **Internal BI & Interactive Dashboards**

The application requires a self-hosted, open-source BI tool that can "plug into" the central application's PostgreSQL database.85 The three leading open-source contenders are Metabase, Apache Superset, and Redash.88

* **Apache Superset:** This is an extremely powerful and feature-rich platform. It offers a "really broad range of complex visualization options" 91 and is often cited for its "best performance".90 However, this power comes at a significant cost: it "requires a good amount of technical expertise and resources to deploy and manage".91 It is a tool *by* data analysts, *for* data analysts.  
* **Metabase:** This tool is designed from the ground up for *ease of use* and *adoption*. It is "super fast to set up" 91 (a simple docker run command is provided 93) and its primary feature is an "intuitive... query builder to write questions without SQL".91 Metabase is "best suited for businesses that need a straightforward way for everyone in the team to self-serve analytics".91  
* **Redash:** In most comparisons, Redash is considered the "least mature" 89 of the three, with "worst community support" and "worst docs quality".90

The best BI tool is the one that actually gets used to make business decisions. A common failure mode for data projects is deploying a powerful tool like Superset, only to find that only two or three data analysts on the team can actually use it. The true value of a data application is unlocked by *democratizing* data.

Metabase's core strength is enabling the *entire team* (sales, marketing, operations, product) to "self-serve analytics" without learning SQL.91 This focus on adoption creates far more business value than Superset's "complex visualization options".92

**Recommendation:** Use **Metabase**.93 It is simple to self-host, connects natively to PostgreSQL 85, and is designed for adoption by the non-technical users who are often the true audience of a data application.

### **Table 4: Open-Source BI Tool Comparison**

| Tool | Setup Complexity | Target User | Visualization Power | Non-Technical User-Friendliness |
| :---- | :---- | :---- | :---- | :---- |
| **Metabase** | **Easy** (Single Docker command 93) | **Everyone** (Non-technical & Analysts) 91 | Medium | **Very High** 91 |
| **Apache Superset** | **Hard** (Requires technical expertise) 91 | **Data Analysts** 91 | **Very High** 92 | Low |
| **Redash** | Medium | Data Analysts | Medium | Medium 89 |

### **Programmatic PDF Report Generation (Python)**

The reporting pillar also includes programmatic, data-driven reports, such as monthly invoices, compliance summaries, or patient histories. These must be generated automatically by the Python service.

The Python ecosystem offers two "families" of tools for this:

1. **HTML-to-PDF Converters:** Tools like PDFKit (which wraps wkhtmltopdf) and WeasyPrint render an HTML/CSS template into a PDF.94 This is fast and easy for "brochure-ware" or simple invoices.  
2. **Programmatic Generators:** Tools that build the PDF element by element, programmatically.

For complex, data-driven reports, programmatic generation is far superior. The "most popular by far" in this category is **ReportLab**.95 While HTML-to-PDF is limited by the constraints of CSS, ReportLab provides "programmatic control and customization" 96 to build "complex layouts and charts" 94 from scratch. It allows the Python service to construct complex, multi-page reports with tables, drawings, and data-driven layouts that are simply not possible with a static HTML template.97

**Recommendation:** Use the **ReportLab** library 97 on the Python analysis service, triggered by an Elixir task, to generate complex, data-driven PDF reports.

### **Real-time Frontend Dashboards (in Phoenix LiveView)**

A key benefit of the Elixir/Phoenix core is the ability to create real-time, in-app dashboards using Phoenix LiveView. This presents a challenge: how to integrate rich, interactive, JavaScript-based charting libraries (like D3.js, ECharts, or Chart.js) 98 into a framework that is explicitly designed to minimize JavaScript.102

The standard, "Elixir way" to solve this is with **LiveView JavaScript Hooks**.102 This pattern perfectly isolates the JavaScript to a "dumb renderer" while keeping all state and logic on the server, in Elixir.

The implementation pattern is as follows:

1. **Elixir/HEEX:** Define a DOM element (e.g., \<canvas\> or \<div\>) and attach the hook. The phx-update="ignore" attribute is critical, as it tells LiveView *not* to touch the DOM element after it's rendered, ceding control to the JavaScript hook.104  
   HTML  
   \<div id\="line\_stack" phx-hook\="Chart" class\="w-full h-\[20rem\]" phx-update\="ignore" /\>

   104  
2. **JavaScript (app.js):** Define the hook in the Hooks object.  
   * In the mounted() callback, initialize the charting library (e.g., echarts.init(this.el)).103  
   * Use this.handleEvent to create a listener for a custom event pushed from the Elixir server.104

JavaScript  
import \* as echarts from "../vendor/echarts.min"

let Hooks \= {};  
Hooks.Chart \= {  
  mounted() {  
    let chart \= echarts.init(this.el)  
    this.handleEvent(\`chart-option-${this.el.id}\`, (option) \=\>  
      chart.setOption(option)  
    )  
  }  
}  
104

3. **Elixir (LiveView):** In the Elixir process (e.g., handle\_info from a PubSub event, or in handle\_params), use push\_event to send the chart data *directly* to the JavaScript hook.105  
   Elixir  
   \# In the LiveView...  
   defp push\_chart\_event(socket, chart\_id, data) do  
     option \= \#... build the ECharts option map...  
     push\_event(socket, "chart-option-\#{chart\_id}", option)  
   end

   104

This pattern represents the "best of both worlds." It fully preserves the LiveView model: all state, data fetching, and aggregation happens in a fault-tolerant Elixir process. The JavaScript hook is "dumb"—it's just a *renderer* that receives data.104 It does not manage state or fetch data itself.

**Recommendation:** Use **ECharts** 101 (for its powerful, comprehensive visualization options) or **Chart.js** 100 (for its simplicity) integrated into Phoenix LiveView using the phx-hook and push\_event pattern.

## **The Integration Blueprint: Elixir/Phoenix Orchestration**

This final section synthesizes all pillars, detailing the *exact* patterns of how the Elixir/Phoenix "control plane" manages the distributed Python "data plane."

### **Orchestration Primitives: Oban vs. Broadway**

The Elixir ecosystem has two primary, and complementary, tools for background work: Oban and Broadway. It is critical to understand their distinct roles.

* **Oban** is a "reliable and observable job processing" tool.106 It is backed by the application's primary PostgreSQL database.31 Oban is designed for **discrete jobs**: "periodic jobs, scheduled jobs, retries".29 It is the Elixir equivalent of Sidekiq (Ruby) or Celery (Python). It is perfect for enqueuing a single unit of work, like "Analyze Document 123."  
* **Broadway** is a "data ingestion and data processing" pipeline.24 It is designed for **continuous streams**: "ingesting high throughout event streams" 29 or "handling... external job queues".30

A common mistake is to view these as competitors. In this architecture, they are not. Oban is for *scheduling* work. Broadway is for *ingesting* data streams (including the *results* of that work).

**Recommendation:** The architecture will use **both**.

1. **Oban** 108: To enqueue, schedule, and persist all discrete "tasks" initiated by the Elixir application.  
2. **Broadway** 24: To ingest the Kafka "data river" (Pillar 1\) and to ingest the *results* from the RabbitMQ "feedback loop" (see below).

### **The Core Integration Pattern (Asynchronous, Decoupled)**

For any long-running (\>= 2 seconds) analysis task, a tightly-coupled, synchronous gRPC call is a liability. The Elixir process should not be blocked waiting for a 2-minute Python analysis.

The most robust, scalable, and decoupled architecture follows this pattern: **Elixir (Oban) \-\> RabbitMQ (Task) \-\> Python (Celery/Pika) \-\> RabbitMQ (Result) \-\> Elixir (Broadway)**.

This workflow unfolds in seven distinct steps:

1. Trigger (Elixir/Phoenix): A user action in the Phoenix LiveView (e.g., uploading a PDF) needs a Python analysis. A new, persistent job is inserted into the database via Oban:  
   %{doc\_id: 123, user\_id: 456} |\> MyApp.Worker.new() |\> Oban.insert().109  
2. Orchestration (Elixir/Oban): An Oban.Worker 111 immediately picks up this job. The worker's only responsibility is to publish this task to the "task broker" (RabbitMQ). It uses Elixir's amqp library 113:  
   AMQP.Basic.publish(chan, "analysis\_tasks", "", Jason.encode\!(%{doc\_id: 123})).115  
   The Oban job's perform/1 function then returns :ok, and the job is marked as "completed" (its task was just to dispatch the work).  
3. **Task Queue (RabbitMQ):** The JSON message {"doc\_id": 123} now sits persistently in the analysis\_tasks queue.117 The Elixir application is now "done" with the request and is free to handle other users.  
4. **Consumption (Python):** A pool of Python workers, built with **Celery** 118 (which is designed for this) or a simple pika consumer 117, is subscribed to the analysis\_tasks queue. A free worker receives the message.  
5. **Execution (Python):** This Python worker performs the long-running, heavy-lifting analysis defined in Pillar 2\. This could take minutes. For example, it:  
   * Fetches the document with doc\_id: 123\.  
   * Runs it through unstructured.io.56  
   * Passes the text to an LLM using outlines and a Pydantic schema.71  
   * Obtains the final, structured JSON result.  
6. Feedback (Python): The worker's job is not done. It must now publish the result. It connects to RabbitMQ and publishes the final JSON to a different queue:  
   channel.basic\_publish(exchange='', routing\_key='analysis\_results', body=result\_json).117  
7. **Result Ingestion (Elixir/Broadway):** A *separate* Elixir **Broadway** pipeline 123 is running continuously, subscribed to the analysis\_results queue. Its handle\_message 123 function receives the final JSON from the Python service. This Elixir process parses the result, updates the application's PostgreSQL database, and (as seen below) notifies the user.

This "full-loop" pattern is the "best of breed" for several reasons:

* **Full Decoupling:** The Elixir and Python services are completely decoupled. They do not know about each other's existence, location, or technology; they only know about RabbitMQ.124  
* **Independent Scalability:** If the analysis tasks are slow, the Python worker pool can be scaled up (e.g., adding more Celery containers) without *any* impact on the Elixir/Phoenix application's performance.  
* **Resilience:** The system has multiple layers of persistence. Oban persists the *intent* to do work.109 RabbitMQ (with durable queues) persists the *task* itself.125 Broadway provides back-pressure for the *results*.28  
* **Specialization:** Each tool is used for what it does best. Oban for scheduling 126, RabbitMQ for task routing 127, Celery for Python execution 118, and Broadway for stream ingestion.31

### **Alternative Pattern (Synchronous, Tightly-Coupled)**

For very fast (\< 2 second) analysis tasks, the full RabbitMQ loop is unnecessary overhead. In this scenario, the Oban.Worker 111 can make a *direct* synchronous or async HTTP call using an Elixir HTTP client like **Tesla** 129 or, preferably, a gRPC call 13 to the Python/FastAPI service. The perform/1 function would await the result.131

This pattern is simpler but *tightly couples* the Elixir worker's lifecycle to the Python service's availability and runtime.124 If the Python service is down or slow, the Oban job will fail and retry, consuming resources on the Elixir side. This pattern should be used sparingly.

### **State Management with GenServer: Closing the Loop**

A critical question remains in the asynchronous pattern: the user's web request in Phoenix finishes in milliseconds, and the Oban job also finishes in milliseconds.132 How does the user (in their LiveView) *know* when the long-running Python job is *actually* done?

The answer is the **GenServer**. A GenServer is the Elixir-native "state machine" to track the lifecycle of the external, polyglot workflow.133

1. When the Oban.Worker 111 runs (Step 2 above), its first action is to start a dedicated JobTracker GenServer (or use a Registry to find one). It calls GenServer.call(pid, {:start,...}).135 The GenServer's internal state is initialized to %{status: :pending}.133  
2. The user's Phoenix LiveView process is *subscribed* to this JobTracker GenServer (e.g., via Phoenix.PubSub or by monitoring the process). The UI shows a "Processing..." spinner.  
3. The Oban worker then publishes to RabbitMQ and finishes.  
4. *Minutes later*, the **Broadway** "results" pipeline (Step 7 above) gets the final result from the Python worker. Its handle\_message function finds the *same* JobTracker GenServer (e.g., by its doc\_id) and sends an asynchronous message: GenServer.cast(pid, {:complete, %{result:...}}).135  
5. The JobTracker GenServer's handle\_cast function fires. It updates its internal state to %{status: :complete, result:...} 133 and then broadcasts a Phoenix.PubSub message.  
6. The user's LiveView, subscribed to that PubSub topic, receives the message, and the UI updates in real-time to show the results.

This GenServer acts as the stateful "glue" that manages and observes the state of the asynchronous, polyglot workflow, providing a seamless, real-time experience to the end user, even for jobs that take minutes to run in a different country on a different tech stack.6

## **Reference Architecture and Recommendations**

### **Summary Flow Diagram**

The final, recommended architecture can be visualized as a set of interconnected data flows:

* Real-time Ingestion (Stream):  
  External Sources \-\> Apache Kafka (Data River) \-\> Elixir Broadway Pipeline \-\> PostgreSQL DB  
* Third-Party Ingestion (Batch):  
  Elixir/Phoenix \-\> Oban Job (Trigger) \-\> gRPC Call \-\> Python/FastAPI (PyAirbyte) \-\> PostgreSQL DB  
* Asynchronous Analysis (Task):  
  Phoenix LiveView (User) \-\> Elixir/Phoenix \-\> Oban Job (Dispatch) \-\> RabbitMQ (analysis\_tasks) \-\> Python (Celery) Worker \-\> \[Pillar 2 Analysis\] \-\> RabbitMQ (analysis\_results) \-\> Elixir Broadway Pipeline (Ingest Result) \-\> PostgreSQL DB \-\> Phoenix.PubSub \-\> Phoenix LiveView (Update)  
* Internal Reporting (BI):  
  Metabase \-\> PostgreSQL DB (Read Replica) \-\> Team Members  
* Internal Reporting (Real-time):  
  PostgreSQL DB \-\> Elixir LiveView (State) \-\> push\_event \-\> JS phx-hook (ECharts) \-\> User Dashboard

### **Final Recommendations Matrix**

This matrix provides a prescriptive summary of the "best of breed" open-source tool for each functional component of the architecture.

| Category | Recommended Tool | Rationale |
| :---- | :---- | :---- |
| **Core Application** | **Elixir / Phoenix** | The highly-concurrent, fault-tolerant "control plane" for orchestration and real-time UI. |
| **Async Task Broker** | **RabbitMQ** | "Smart broker" for decoupled, stateful, task-based commands.17 |
| **Async Data Stream** | **Apache Kafka** | "Durable log" for high-throughput, real-time "data river" ingestion.16 |
| **Task Orchestration (Elixir)** | **Oban** | The PostgreSQL-backed, reliable job processor for *dispatching* Elixir-based tasks.106 |
| **Stream Processing (Elixir)** | **Broadway** | The GenStage-based pipeline for consuming Kafka/RabbitMQ *streams* with back-pressure.24 |
| **Batch Ingestion** | **Airbyte (with PyAirbyte)** | 600+ connectors 35 with a first-class Python library 36 for programmatic control. |
| **Batch Orchestration** | **Dagster** or **Apache Airflow** | Python-native, DAG-based workflow managers for complex dependencies.36 |
| **Analysis Service Framework** | **Python (FastAPI)** | High-performance, async, Pydantic-native framework for the "data plane".15 |
| **Unstructured Parsing** | **unstructured.io** | AI-native framework with "strategies" for semantic chunking and integrated OCR.56 |
| **Structured LLM Extraction** | **outlines (with pydantic)** | Model-agnostic, Pydantic-native library that *guarantees* valid JSON schema output.71 |
| **Internal BI Dashboard** | **Metabase** | "Fast to set up" 91 and designed for adoption by *non-technical* users.93 |
| **Programmatic PDF Reports** | **ReportLab** | Programmatic control for complex, data-driven layouts beyond HTML/CSS.94 |
| **Real-time Charts (in-app)** | **ECharts (via phx-hook)** | Powerful JS charts driven by server-side Elixir logic via push\_event.104 |
| **Interservice RPC** | **gRPC** | High-performance, schema-enforced communication ideal for polyglot systems.9 |

#### **Works cited**

1. Polyglot Architecture \- Confluent Developer, accessed November 17, 2025, [https://developer.confluent.io/courses/microservices/polyglot-architecture/](https://developer.confluent.io/courses/microservices/polyglot-architecture/)  
2. Considering Porting my Startup to Elixir/Phoenix \- Looking for advice \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/elixir/comments/1lv5rz1/considering\_porting\_my\_startup\_to\_elixirphoenix/](https://www.reddit.com/r/elixir/comments/1lv5rz1/considering_porting_my_startup_to_elixirphoenix/)  
3. Massive distributed parallel processing of large data sets with Elixir? \- Questions / Help, accessed November 17, 2025, [https://elixirforum.com/t/massive-distributed-parallel-processing-of-large-data-sets-with-elixir/49584](https://elixirforum.com/t/massive-distributed-parallel-processing-of-large-data-sets-with-elixir/49584)  
4. If you were in charge of a startup tech stack, how would you use elixir to actually scale and make every work seamlessly? \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/elixir/comments/vkbzio/if\_you\_were\_in\_charge\_of\_a\_startup\_tech\_stack\_how/](https://www.reddit.com/r/elixir/comments/vkbzio/if_you_were_in_charge_of_a_startup_tech_stack_how/)  
5. Elixir Phoenix use cases ? Why start using it?, accessed November 17, 2025, [https://elixirforum.com/t/elixir-phoenix-use-cases-why-start-using-it/50924](https://elixirforum.com/t/elixir-phoenix-use-cases-why-start-using-it/50924)  
6. What is a well-used microservices architecture for Python / Elixir to coexist? \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/elixir/comments/gkxmeu/what\_is\_a\_wellused\_microservices\_architecture\_for/](https://www.reddit.com/r/elixir/comments/gkxmeu/what_is_a_wellused_microservices_architecture_for/)  
7. 10 Best Python ETL Tools to Consider in 2025 \- Hevo Data, accessed November 17, 2025, [https://hevodata.com/learn/python-etl-tools/](https://hevodata.com/learn/python-etl-tools/)  
8. gRPC vs REST \- Difference Between Application Designs \- Amazon AWS, accessed November 17, 2025, [https://aws.amazon.com/compare/the-difference-between-grpc-and-rest/](https://aws.amazon.com/compare/the-difference-between-grpc-and-rest/)  
9. A Deep Dive into Communication Styles for Microservices: REST vs. gRPC vs. Message Queues | by Platform Engineers | Medium, accessed November 17, 2025, [https://medium.com/@platform.engineers/a-deep-dive-into-communication-styles-for-microservices-rest-vs-grpc-vs-message-queues-ea72011173b3](https://medium.com/@platform.engineers/a-deep-dive-into-communication-styles-for-microservices-rest-vs-grpc-vs-message-queues-ea72011173b3)  
10. Implementing gRPC In Python: A Step-by-step Guide \- Velotio, accessed November 17, 2025, [https://www.velotio.com/engineering-blog/grpc-implementation-using-python](https://www.velotio.com/engineering-blog/grpc-implementation-using-python)  
11. Basics tutorial | Python \- gRPC, accessed November 17, 2025, [https://grpc.io/docs/languages/python/basics/](https://grpc.io/docs/languages/python/basics/)  
12. How to Use gRPC in Elixir \- AppSignal Blog, accessed November 17, 2025, [https://blog.appsignal.com/2020/03/24/how-to-use-grpc-in-elixir.html](https://blog.appsignal.com/2020/03/24/how-to-use-grpc-in-elixir.html)  
13. How optimizable is Elixir for raw throughput when compared to Go? \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/elixir/comments/1m77pkg/how\_optimizable\_is\_elixir\_for\_raw\_throughput\_when/](https://www.reddit.com/r/elixir/comments/1m77pkg/how_optimizable_is_elixir_for_raw_throughput_when/)  
14. Grpc elixir to python with websocket, accessed November 17, 2025, [https://elixirforum.com/t/grpc-elixir-to-python-with-websocket/50829](https://elixirforum.com/t/grpc-elixir-to-python-with-websocket/50829)  
15. FastAPI, accessed November 17, 2025, [https://fastapi.tiangolo.com/](https://fastapi.tiangolo.com/)  
16. What's the Difference Between Kafka and RabbitMQ? \- Amazon AWS, accessed November 17, 2025, [https://aws.amazon.com/compare/the-difference-between-rabbitmq-and-kafka/](https://aws.amazon.com/compare/the-difference-between-rabbitmq-and-kafka/)  
17. Kafka Vs RabbitMQ: Key Differences & Features Explained \- Simplilearn.com, accessed November 17, 2025, [https://www.simplilearn.com/kafka-vs-rabbitmq-article](https://www.simplilearn.com/kafka-vs-rabbitmq-article)  
18. RabbitMQ vs. Kafka \- LogicMonitor, accessed November 17, 2025, [https://www.logicmonitor.com/blog/rabbitmq-vs-kafka](https://www.logicmonitor.com/blog/rabbitmq-vs-kafka)  
19. When to use RabbitMQ over Kafka? \[closed\] \- Stack Overflow, accessed November 17, 2025, [https://stackoverflow.com/questions/42151544/when-to-use-rabbitmq-over-kafka](https://stackoverflow.com/questions/42151544/when-to-use-rabbitmq-over-kafka)  
20. Polyglot Microservices Architecture using Dapr | by Bakht Munir \- Medium, accessed November 17, 2025, [https://medium.com/@bakhtmunir/polyglot-microservices-architecure-using-dapr-36ef17a7782e](https://medium.com/@bakhtmunir/polyglot-microservices-architecure-using-dapr-36ef17a7782e)  
21. Microservice communication using Dapr's Service Invocation API (Python) \- Code Samples, accessed November 17, 2025, [https://learn.microsoft.com/en-us/samples/azure-samples/svc-invoke-dapr-python/svc-invoke-dapr-python/](https://learn.microsoft.com/en-us/samples/azure-samples/svc-invoke-dapr-python/svc-invoke-dapr-python/)  
22. 3/3 Polyglot microservice development with Dapr \- What options are available to simplify the ... \- white duck, accessed November 17, 2025, [https://whiteduck.de/what-options-are-available-to-simplify-the-development-of-polyglot-microservices/](https://whiteduck.de/what-options-are-available-to-simplify-the-development-of-polyglot-microservices/)  
23. Building Cross-Language Microservices with Dapr | Diagrid Videos, accessed November 17, 2025, [https://www.diagrid.io/videos/building-cross-language-microservices-with-dapr](https://www.diagrid.io/videos/building-cross-language-microservices-with-dapr)  
24. dashbitco/broadway: Concurrent and multi-stage data ingestion and data processing with Elixir \- GitHub, accessed November 17, 2025, [https://github.com/dashbitco/broadway](https://github.com/dashbitco/broadway)  
25. Elixir Broadway, accessed November 17, 2025, [https://elixir-broadway.org/](https://elixir-broadway.org/)  
26. Broadway v1.2.1 \- Hexdocs, accessed November 17, 2025, [https://hexdocs.pm/broadway/Broadway.html](https://hexdocs.pm/broadway/Broadway.html)  
27. How to Use Broadway in Your Elixir Application \- AppSignal Blog, accessed November 17, 2025, [https://blog.appsignal.com/2019/12/12/how-to-use-broadway-in-your-elixir-application.html](https://blog.appsignal.com/2019/12/12/how-to-use-broadway-in-your-elixir-application.html)  
28. Constructing effective data processing workflows using Elixir and Broadway \- SoftwareMill, accessed November 17, 2025, [https://softwaremill.com/constructing-effective-data-processing-workflows-using-elixir-and-broadway/](https://softwaremill.com/constructing-effective-data-processing-workflows-using-elixir-and-broadway/)  
29. Is Broadway suitable for this task? \- Questions / Help \- Elixir Programming Language Forum, accessed November 17, 2025, [https://elixirforum.com/t/is-broadway-suitable-for-this-task/29056](https://elixirforum.com/t/is-broadway-suitable-for-this-task/29056)  
30. A Comparative Dive into Elixir's Oban and Broadway \- ElixirConf EU, accessed November 17, 2025, [https://www.elixirconf.eu/talks/a-comparative-dive-into-elixirs-oban-and-broadway/](https://www.elixirconf.eu/talks/a-comparative-dive-into-elixirs-oban-and-broadway/)  
31. Elixir background jobs: choosing the right tool for the job \- Honeybadger Developer Blog, accessed November 17, 2025, [https://www.honeybadger.io/blog/elixir-background-jobs/](https://www.honeybadger.io/blog/elixir-background-jobs/)  
32. Towards the killer Open Source ELT/ETL | by Pawel Plaszczak \- Medium, accessed November 17, 2025, [https://medium.com/@pp\_85623/towards-the-killer-open-source-elt-etl-4270df7d3d93](https://medium.com/@pp_85623/towards-the-killer-open-source-elt-etl-4270df7d3d93)  
33. 10 Data Ingestion Tools to Know in 2025: Open Source \+ Paid | Dagster Guides, accessed November 17, 2025, [https://dagster.io/guides/10-data-ingestion-tools-to-know-in-2025-open-source-paid](https://dagster.io/guides/10-data-ingestion-tools-to-know-in-2025-open-source-paid)  
34. Airbyte vs Meltano community support : r/dataengineering \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/dataengineering/comments/vr67uk/airbyte\_vs\_meltano\_community\_support/](https://www.reddit.com/r/dataengineering/comments/vr67uk/airbyte_vs_meltano_community_support/)  
35. Top 10 Open Source Data Ingestion Tools in 2025 \- Airbyte, accessed November 17, 2025, [https://airbyte.com/top-etl-tools-for-sources/open-source-data-ingestion-tools](https://airbyte.com/top-etl-tools-for-sources/open-source-data-ingestion-tools)  
36. 10 Python ETL Tools That'll Actually Matter in 2025 \- Airbyte, accessed November 17, 2025, [https://airbyte.com/top-etl-tools-for-sources/python-etl-tools](https://airbyte.com/top-etl-tools-for-sources/python-etl-tools)  
37. A curated list of awesome open source workflow engines \- GitHub, accessed November 17, 2025, [https://github.com/meirwah/awesome-workflow-engines](https://github.com/meirwah/awesome-workflow-engines)  
38. Top Open Source ETL Frameworks in 2025 \+ Alternatives | Integrate.io, accessed November 17, 2025, [https://www.integrate.io/blog/open-source-etl-frameworks-revolutionizing-data-integration/](https://www.integrate.io/blog/open-source-etl-frameworks-revolutionizing-data-integration/)  
39. What are the best open source tools for ETL? : r/dataengineering \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/dataengineering/comments/163jj1f/what\_are\_the\_best\_open\_source\_tools\_for\_etl/](https://www.reddit.com/r/dataengineering/comments/163jj1f/what_are_the_best_open_source_tools_for_etl/)  
40. FastAPI Best Practices: A Condensed Guide with Examples \- DEV Community, accessed November 17, 2025, [https://dev.to/devasservice/fastapi-best-practices-a-condensed-guide-with-examples-3pa5](https://dev.to/devasservice/fastapi-best-practices-a-condensed-guide-with-examples-3pa5)  
41. FastAPI Best Practices and Conventions we used at our startup \- GitHub, accessed November 17, 2025, [https://github.com/zhanymkanov/fastapi-best-practices](https://github.com/zhanymkanov/fastapi-best-practices)  
42. From Data to Dashboard: Building a Production-Ready App with Streamlit, FastAPI, Supabase, and Docker | by João Escórcio | Medium, accessed November 17, 2025, [https://medium.com/@jv.escorcio/from-data-to-dashboard-building-a-production-ready-app-with-streamlit-fastapi-supabase-and-65e1cf1a1673](https://medium.com/@jv.escorcio/from-data-to-dashboard-building-a-production-ready-app-with-streamlit-fastapi-supabase-and-65e1cf1a1673)  
43. Server Workers \- Uvicorn with Workers \- FastAPI, accessed November 17, 2025, [https://fastapi.tiangolo.com/deployment/server-workers/](https://fastapi.tiangolo.com/deployment/server-workers/)  
44. How to Parse a PDF, Part 1 \- Unstructured, accessed November 17, 2025, [https://unstructured.io/blog/how-to-parse-a-pdf-part-1](https://unstructured.io/blog/how-to-parse-a-pdf-part-1)  
45. Python Libraries to Extract Tables From PDF: A Comparison \- Unstract, accessed November 17, 2025, [https://unstract.com/blog/extract-tables-from-pdf-python/](https://unstract.com/blog/extract-tables-from-pdf-python/)  
46. Extracting Data from PDFs | Challenges in RAG/LLM Applications \- Unstract, accessed November 17, 2025, [https://unstract.com/blog/pdf-hell-and-practical-rag-applications/](https://unstract.com/blog/pdf-hell-and-practical-rag-applications/)  
47. How to parse complex documents for RAG | by Pablo Guzmán \- Medium, accessed November 17, 2025, [https://p-guzman-salas.medium.com/how-to-parse-complex-documents-for-rag-68b6ff67a215](https://p-guzman-salas.medium.com/how-to-parse-complex-documents-for-rag-68b6ff67a215)  
48. 7 Free Python PDF Libraries You Should Know in 2025 | by Kevin Meneses González, accessed November 17, 2025, [https://python.plainenglish.io/7-free-python-pdf-libraries-you-should-know-in-2025-3eeda54188d3](https://python.plainenglish.io/7-free-python-pdf-libraries-you-should-know-in-2025-3eeda54188d3)  
49. An Evaluation of Python PDF to Text Parser Libraries \- Unstract, accessed November 17, 2025, [https://unstract.com/blog/evaluating-python-pdf-to-text-libraries/](https://unstract.com/blog/evaluating-python-pdf-to-text-libraries/)  
50. I Tested 7 Python PDF Extractors So You Don't Have To (2025 Edition) \- Aman Kumar, accessed November 17, 2025, [https://onlyoneaman.medium.com/i-tested-7-python-pdf-extractors-so-you-dont-have-to-2025-edition-c88013922257](https://onlyoneaman.medium.com/i-tested-7-python-pdf-extractors-so-you-dont-have-to-2025-edition-c88013922257)  
51. Top Python libraries for text extraction from PDFs \- AZ Big Media, accessed November 17, 2025, [https://azbigmedia.com/business/top-python-libraries-for-text-extraction-from-pdfs/](https://azbigmedia.com/business/top-python-libraries-for-text-extraction-from-pdfs/)  
52. A Comparative Study of PDF Parsing Tools Across Diverse Document Categories \- arXiv, accessed November 17, 2025, [https://arxiv.org/html/2410.09871v1](https://arxiv.org/html/2410.09871v1)  
53. What's the Best Python Library for Extracting Text from PDFs? : r/LangChain \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/LangChain/comments/1e7cntq/whats\_the\_best\_python\_library\_for\_extracting\_text/](https://www.reddit.com/r/LangChain/comments/1e7cntq/whats_the_best_python_library_for_extracting_text/)  
54. A Comparison of python libraries for PDF Data Extraction for text, images and tables, accessed November 17, 2025, [https://pradeepundefned.medium.com/a-comparison-of-python-libraries-for-pdf-data-extraction-for-text-images-and-tables-c75e5dbcfef8](https://pradeepundefned.medium.com/a-comparison-of-python-libraries-for-pdf-data-extraction-for-text-images-and-tables-c75e5dbcfef8)  
55. How to Process PDFs in Python: A Step-by-Step Guide | Unstructured, accessed November 17, 2025, [https://unstructured.io/blog/how-to-process-pdf-in-python](https://unstructured.io/blog/how-to-process-pdf-in-python)  
56. Partitioning \- Unstructured, accessed November 17, 2025, [https://docs.unstructured.io/open-source/core-functionality/partitioning](https://docs.unstructured.io/open-source/core-functionality/partitioning)  
57. RAG — Three Python libraries for Pipeline-based PDF parsing \- AI Bites, accessed November 17, 2025, [https://www.ai-bites.net/rag-three-python-libraries-for-pipeline-based-pdf-parsing/](https://www.ai-bites.net/rag-three-python-libraries-for-pipeline-based-pdf-parsing/)  
58. Partitioning strategies \- Unstructured, accessed November 17, 2025, [https://docs.unstructured.io/api-reference/partition/partitioning](https://docs.unstructured.io/api-reference/partition/partitioning)  
59. 10 Open Source OCR Tools You Should Know About \- Koncile, accessed November 17, 2025, [https://www.koncile.ai/en/ressources/10-open-source-ocr-tools-you-should-know-about](https://www.koncile.ai/en/ressources/10-open-source-ocr-tools-you-should-know-about)  
60. Top 8 OCR Libraries in Python to Extract Text from Image \- Analytics Vidhya, accessed November 17, 2025, [https://www.analyticsvidhya.com/blog/2024/04/ocr-libraries-in-python/](https://www.analyticsvidhya.com/blog/2024/04/ocr-libraries-in-python/)  
61. 7 Free Python PDF Libraries You Should Know in 2025 \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/Python/comments/1naohtd/7\_free\_python\_pdf\_libraries\_you\_should\_know\_in/](https://www.reddit.com/r/Python/comments/1naohtd/7_free_python_pdf_libraries_you_should_know_in/)  
62. pip install marker-pdf==0.3.2 \- PyPI, accessed November 17, 2025, [https://pypi.org/project/marker-pdf/0.3.2/](https://pypi.org/project/marker-pdf/0.3.2/)  
63. datalab-to/marker: Convert PDF to markdown \+ JSON ... \- GitHub, accessed November 17, 2025, [https://github.com/datalab-to/marker](https://github.com/datalab-to/marker)  
64. Forcing LLM JSON Outputs: How to make LLM output complex JSONs | by Diana Zagirova, accessed November 17, 2025, [https://medium.com/@d.zagirowa/forcing-llm-json-outputs-how-to-make-llm-output-complex-jsons-a8bb00e87f71](https://medium.com/@d.zagirowa/forcing-llm-json-outputs-how-to-make-llm-output-complex-jsons-a8bb00e87f71)  
65. Introduction to Structured Data Extraction | LlamaIndex Python Documentation, accessed November 17, 2025, [https://developers.llamaindex.ai/python/framework/understanding/extraction/](https://developers.llamaindex.ai/python/framework/understanding/extraction/)  
66. Pydantic AI, accessed November 17, 2025, [https://ai.pydantic.dev/](https://ai.pydantic.dev/)  
67. Structured Outputs from LLM using Pydantic | by Harisudhan.S \- Medium, accessed November 17, 2025, [https://medium.com/@speaktoharisudhan/structured-outputs-from-llm-using-pydantic-1a36e6c3aa07](https://medium.com/@speaktoharisudhan/structured-outputs-from-llm-using-pydantic-1a36e6c3aa07)  
68. How to Use Pydantic for LLMs: Schema, Validation & Prompts description, accessed November 17, 2025, [https://pydantic.dev/articles/llm-intro](https://pydantic.dev/articles/llm-intro)  
69. Structured Data Extraction from Unstructured Text Python LLMs Ollama Pydantic Llama 3.2 Granite 3.2 \- YouTube, accessed November 17, 2025, [https://www.youtube.com/watch?v=dJsTkj9xCKA](https://www.youtube.com/watch?v=dJsTkj9xCKA)  
70. How can I get LLM to only respond in JSON strings? \- Stack Overflow, accessed November 17, 2025, [https://stackoverflow.com/questions/77407632/how-can-i-get-llm-to-only-respond-in-json-strings](https://stackoverflow.com/questions/77407632/how-can-i-get-llm-to-only-respond-in-json-strings)  
71. dottxt-ai/outlines: Structured Outputs \- GitHub, accessed November 17, 2025, [https://github.com/dottxt-ai/outlines](https://github.com/dottxt-ai/outlines)  
72. Experience with structured responses using local llamas (jsonformer, guidance, gorilla, etc?) : r/LocalLLaMA \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/LocalLLaMA/comments/14zs7jp/experience\_with\_structured\_responses\_using\_local/](https://www.reddit.com/r/LocalLLaMA/comments/14zs7jp/experience_with_structured_responses_using_local/)  
73. Python libraries for LLM structured outputs beyond LangChain | by Andrew Docherty, accessed November 17, 2025, [https://medium.com/@docherty/python-libraries-for-llm-structured-outputs-beyond-langchain-621225e48399](https://medium.com/@docherty/python-libraries-for-llm-structured-outputs-beyond-langchain-621225e48399)  
74. Enforcing JSON outputs on LLMs | Modal Docs, accessed November 17, 2025, [https://modal.com/docs/examples/outlines\_generate](https://modal.com/docs/examples/outlines_generate)  
75. 8 Top Open-Source OCR Models Compared: A Complete Guide | Modal Blog, accessed November 17, 2025, [https://modal.com/blog/8-top-open-source-ocr-models-compared](https://modal.com/blog/8-top-open-source-ocr-models-compared)  
76. scispacy | SpaCy models for biomedical text processing \- GitHub Pages, accessed November 17, 2025, [https://allenai.github.io/scispacy/](https://allenai.github.io/scispacy/)  
77. Clinical named-entity recognition: A short comparison \- PMC \- NIH, accessed November 17, 2025, [https://pmc.ncbi.nlm.nih.gov/articles/PMC9028678/](https://pmc.ncbi.nlm.nih.gov/articles/PMC9028678/)  
78. allenai/scispacy: A full spaCy pipeline and models for scientific/biomedical documents. \- GitHub, accessed November 17, 2025, [https://github.com/allenai/scispacy](https://github.com/allenai/scispacy)  
79. Clinical Biomedical Named Entity Recognition (NLP) Using Scispacy \- Medium, accessed November 17, 2025, [https://medium.com/@ndubisiprecious/clinical-biomedical-named-entity-recognition-nlp-using-scispacy-80fcfa1cf648](https://medium.com/@ndubisiprecious/clinical-biomedical-named-entity-recognition-nlp-using-scispacy-80fcfa1cf648)  
80. Exploring Biomedical Named Entity Recognition via SciSpaCy and BioBERT Models, accessed November 17, 2025, [https://openbiomedicalengineeringjournal.com/VOLUME/18/ELOCATOR/e18741207289680/](https://openbiomedicalengineeringjournal.com/VOLUME/18/ELOCATOR/e18741207289680/)  
81. emilyalsentzer/Bio\_ClinicalBERT \- Hugging Face, accessed November 17, 2025, [https://huggingface.co/emilyalsentzer/Bio\_ClinicalBERT](https://huggingface.co/emilyalsentzer/Bio_ClinicalBERT)  
82. Simonlee711/Clinical\_ModernBERT \- Hugging Face, accessed November 17, 2025, [https://huggingface.co/Simonlee711/Clinical\_ModernBERT](https://huggingface.co/Simonlee711/Clinical_ModernBERT)  
83. Summarization \- Hugging Face, accessed November 17, 2025, [https://huggingface.co/docs/transformers/tasks/summarization](https://huggingface.co/docs/transformers/tasks/summarization)  
84. Unlocking Healthcare AI: I'm Releasing State-of-the-Art Medical Models for Free. Forever. \- Hugging Face, accessed November 17, 2025, [https://huggingface.co/blog/MaziyarPanahi/open-health-ai](https://huggingface.co/blog/MaziyarPanahi/open-health-ai)  
85. 20 Best open source BI Tools of 2025 \- Explo, accessed November 17, 2025, [https://www.explo.co/blog/open-source-bi-tools](https://www.explo.co/blog/open-source-bi-tools)  
86. 9 Best PostgreSQL Reporting Tools in 2025 \- Domo, accessed November 17, 2025, [https://www.domo.com/learn/article/postgresql-reporting-tools](https://www.domo.com/learn/article/postgresql-reporting-tools)  
87. Best simple/cheap BI tool that can plug into a Postgres database? \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/BusinessIntelligence/comments/1ii0evr/best\_simplecheap\_bi\_tool\_that\_can\_plug\_into\_a/](https://www.reddit.com/r/BusinessIntelligence/comments/1ii0evr/best_simplecheap_bi_tool_that_can_plug_into_a/)  
88. Metabase vs Redash: Which Data Tool Is Best in 2025? \- YouTube, accessed November 17, 2025, [https://www.youtube.com/watch?v=j4l3BBhHRqU](https://www.youtube.com/watch?v=j4l3BBhHRqU)  
89. Choosing an Analytics Tool. Metabase Vs Superset Vs Redash | by Stefan Mihaylov, accessed November 17, 2025, [https://medium.com/vortechsa/choosing-an-analytics-tool-metabase-vs-superset-vs-redash-afd88e028ba9](https://medium.com/vortechsa/choosing-an-analytics-tool-metabase-vs-superset-vs-redash-afd88e028ba9)  
90. Comparison of Open Source visualization tools \- Grafana vs Superset vs Metabase vs Redash : r/dataengineering \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/dataengineering/comments/1cxbnd7/comparison\_of\_open\_source\_visualization\_tools/](https://www.reddit.com/r/dataengineering/comments/1cxbnd7/comparison_of_open_source_visualization_tools/)  
91. Metabase vs. Superset, accessed November 17, 2025, [https://www.metabase.com/lp/metabase-vs-superset](https://www.metabase.com/lp/metabase-vs-superset)  
92. Metabase vs Apache Superset: Which is best for your team? \- YouTube, accessed November 17, 2025, [https://www.youtube.com/watch?v=HXzob4kvlSM](https://www.youtube.com/watch?v=HXzob4kvlSM)  
93. Open source Business Intelligence and Embedded Analytics, accessed November 17, 2025, [https://www.metabase.com/](https://www.metabase.com/)  
94. Top 10 Python PDF generator libraries: Complete guide for developers (2025), accessed November 17, 2025, [https://www.nutrient.io/blog/top-10-ways-to-generate-pdfs-in-python/](https://www.nutrient.io/blog/top-10-ways-to-generate-pdfs-in-python/)  
95. Best Python library for generating PDFs? \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/Python/comments/82z6cw/best\_python\_library\_for\_generating\_pdfs/](https://www.reddit.com/r/Python/comments/82z6cw/best_python_library_for_generating_pdfs/)  
96. How to Generate PDF Using ReportLab in Python (Updated 2025\) \- Pdforge, accessed November 17, 2025, [https://pdforge.com/blog/how-to-generate-pdf-from-html-using-reportlab-in-python](https://pdforge.com/blog/how-to-generate-pdf-from-html-using-reportlab-in-python)  
97. Creating PDF Reports with Python. Introduction | by Alexander Obregon \- Medium, accessed November 17, 2025, [https://medium.com/@AlexanderObregon/creating-pdf-reports-with-python-a53439031117](https://medium.com/@AlexanderObregon/creating-pdf-reports-with-python-a53439031117)  
98. Most stable JS framework to use with Phoenix and LiveView? : r/elixir \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/elixir/comments/1o5c63y/most\_stable\_js\_framework\_to\_use\_with\_phoenix\_and/](https://www.reddit.com/r/elixir/comments/1o5c63y/most_stable_js_framework_to_use_with_phoenix_and/)  
99. How to use d3.js in Phoenix? \- javascript \- Stack Overflow, accessed November 17, 2025, [https://stackoverflow.com/questions/41028219/how-to-use-d3-js-in-phoenix](https://stackoverflow.com/questions/41028219/how-to-use-d3-js-in-phoenix)  
100. Chart.js | Open source HTML5 Charts for your website, accessed November 17, 2025, [https://www.chartjs.org/](https://www.chartjs.org/)  
101. Apache ECharts, accessed November 17, 2025, [https://echarts.apache.org/](https://echarts.apache.org/)  
102. Using D3.js with Phoenix LiveView? \- Elixir Forum, accessed November 17, 2025, [https://elixirforum.com/t/using-d3-js-with-phoenix-liveview/61604](https://elixirforum.com/t/using-d3-js-with-phoenix-liveview/61604)  
103. Integrating Chart.js into Elixir Phoenix for visual impact | by Lionel Aimerie | Medium, accessed November 17, 2025, [https://medium.com/@lionel.aimerie/integrating-chart-js-into-elixir-phoenix-for-visual-impact-9a3991f0690f](https://medium.com/@lionel.aimerie/integrating-chart-js-into-elixir-phoenix-for-visual-impact-9a3991f0690f)  
104. ECharts in Phoenix LiveView \- Dan Schultzer, accessed November 17, 2025, [https://danschultzer.com/posts/echarts-phoenix-liveview](https://danschultzer.com/posts/echarts-phoenix-liveview)  
105. Using LivieView with chart.js whats it like to feed data to a js lib? \- Elixir Forum, accessed November 17, 2025, [https://elixirforum.com/t/using-livieview-with-chart-js-whats-it-like-to-feed-data-to-a-js-lib/40001](https://elixirforum.com/t/using-livieview-with-chart-js-whats-it-like-to-feed-data-to-a-js-lib/40001)  
106. Oban — Reliable and Observable Job Processing \- Elixir Forum, accessed November 17, 2025, [https://elixirforum.com/t/oban-reliable-and-observable-job-processing/22449](https://elixirforum.com/t/oban-reliable-and-observable-job-processing/22449)  
107. Background Job Processing in Elixir with Oban \- ⚡️ Blixt Dev ⚡️, accessed November 17, 2025, [https://blixtdev.com/background-job-processing-in-elixir-with-oban/](https://blixtdev.com/background-job-processing-in-elixir-with-oban/)  
108. Sophisticated job processing for the Elixir ecosystem · Oban Pro, accessed November 17, 2025, [https://oban.pro/](https://oban.pro/)  
109. oban-bg/oban: Robust job processing in Elixir, backed by modern PostgreSQL, SQLite3, and MySQL \- GitHub, accessed November 17, 2025, [https://github.com/oban-bg/oban](https://github.com/oban-bg/oban)  
110. Oban v2.20.1 \- Hexdocs, accessed November 17, 2025, [https://hexdocs.pm/oban/Oban.html](https://hexdocs.pm/oban/Oban.html)  
111. Oban.Worker — Oban v2.20.1 \- Hexdocs, accessed November 17, 2025, [https://hexdocs.pm/oban/Oban.Worker.html](https://hexdocs.pm/oban/Oban.Worker.html)  
112. Keep Calm and Let Oban Handle Your Elixir Background Jobs \- Medium, accessed November 17, 2025, [https://medium.com/@jonnyeberhardt7/keep-calm-and-let-oban-handle-your-elixir-background-jobs-67e4f04d7522](https://medium.com/@jonnyeberhardt7/keep-calm-and-let-oban-handle-your-elixir-background-jobs-67e4f04d7522)  
113. RabbitMQ tutorial \- Publish/Subscribe, accessed November 17, 2025, [https://www.rabbitmq.com/tutorials/tutorial-three-elixir](https://www.rabbitmq.com/tutorials/tutorial-three-elixir)  
114. Elixir Basics: Working with AMQP \- James Carr, accessed November 17, 2025, [https://james-carr.org/posts/2024-10-15-elixir-basics-working-with-amqp/](https://james-carr.org/posts/2024-10-15-elixir-basics-working-with-amqp/)  
115. AMQP.Basic — amqp v4.1.0 \- Hexdocs, accessed November 17, 2025, [https://hexdocs.pm/amqp/AMQP.Basic.html](https://hexdocs.pm/amqp/AMQP.Basic.html)  
116. Help: How to use AMQP channel from pool for publishing messages? \- Elixir Forum, accessed November 17, 2025, [https://elixirforum.com/t/help-how-to-use-amqp-channel-from-pool-for-publishing-messages/46684](https://elixirforum.com/t/help-how-to-use-amqp-channel-from-pool-for-publishing-messages/46684)  
117. RabbitMQ tutorial \- "Hello world\!", accessed November 17, 2025, [https://www.rabbitmq.com/tutorials/tutorial-one-python](https://www.rabbitmq.com/tutorials/tutorial-one-python)  
118. A basic overview of how to implement a task queue using Celery & RabbitMQ broker. \- GitHub, accessed November 17, 2025, [https://github.com/iamsarthakjoshi/python-celery-rabbitmq](https://github.com/iamsarthakjoshi/python-celery-rabbitmq)  
119. How to Set Up a Task Queue with Celery and RabbitMQ | Linode Docs, accessed November 17, 2025, [https://www.linode.com/docs/guides/task-queue-celery-rabbitmq/](https://www.linode.com/docs/guides/task-queue-celery-rabbitmq/)  
120. Asynchronous consumer example — pika 1.3.2 documentation \- Read the Docs, accessed November 17, 2025, [https://pika.readthedocs.io/en/stable/examples/asynchronous\_consumer\_example.html](https://pika.readthedocs.io/en/stable/examples/asynchronous_consumer_example.html)  
121. RabbitMQ tutorial \- Work Queues, accessed November 17, 2025, [https://www.rabbitmq.com/tutorials/tutorial-two-python](https://www.rabbitmq.com/tutorials/tutorial-two-python)  
122. Normal flow of read message, do something with the message, and then write the message to another queue · pika pika · Discussion \#1427 \- GitHub, accessed November 17, 2025, [https://github.com/pika/pika/discussions/1427](https://github.com/pika/pika/discussions/1427)  
123. dashbitco/broadway\_rabbitmq: A Broadway producer for ... \- GitHub, accessed November 17, 2025, [https://github.com/dashbitco/broadway\_rabbitmq](https://github.com/dashbitco/broadway_rabbitmq)  
124. Which option is more suitable for microservice? GRPC or Message Brokers like RabbitMQ \[closed\] \- Stack Overflow, accessed November 17, 2025, [https://stackoverflow.com/questions/69416765/which-option-is-more-suitable-for-microservice-grpc-or-message-brokers-like-rab](https://stackoverflow.com/questions/69416765/which-option-is-more-suitable-for-microservice-grpc-or-message-brokers-like-rab)  
125. Efficient and reliable message publishing with RabbitMQ and Elixir \- DEV Community, accessed November 17, 2025, [https://dev.to/palm86/efficient-and-reliable-message-publishing-with-rabbitmq-and-elixir-58e4](https://dev.to/palm86/efficient-and-reliable-message-publishing-with-rabbitmq-and-elixir-58e4)  
126. How to create an orchestrator for background jobs in Elixir with Oban and Broadway, accessed November 17, 2025, [https://medium.com/@vini\_roland/how-to-create-an-orchestrator-for-background-jobs-in-elixir-with-oban-and-broadway-170bed16f0a3](https://medium.com/@vini_roland/how-to-create-an-orchestrator-for-background-jobs-in-elixir-with-oban-and-broadway-170bed16f0a3)  
127. What's the difference between Oban and RabbitMQ \- Elixir Forum, accessed November 17, 2025, [https://elixirforum.com/t/whats-the-difference-between-oban-and-rabbitmq/37314](https://elixirforum.com/t/whats-the-difference-between-oban-and-rabbitmq/37314)  
128. What's the difference between Oban and RabbitMQ : r/elixir \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/elixir/comments/lch6ek/whats\_the\_difference\_between\_oban\_and\_rabbitmq/](https://www.reddit.com/r/elixir/comments/lch6ek/whats_the_difference_between_oban_and_rabbitmq/)  
129. elixir-tesla/tesla: The flexible HTTP client library for Elixir, with support for middleware and multiple adapters. \- GitHub, accessed November 17, 2025, [https://github.com/elixir-tesla/tesla](https://github.com/elixir-tesla/tesla)  
130. Tesla HTTP Client Monitoring for Elixir with AppSignal, accessed November 17, 2025, [https://www.appsignal.com/elixir/tesla-monitoring](https://www.appsignal.com/elixir/tesla-monitoring)  
131. Spawning Task vs enqueuing another Oban worker from within an Oban worker \- Oban \- Elixir Programming Language Forum, accessed November 17, 2025, [https://elixirforum.com/t/spawning-task-vs-enqueuing-another-oban-worker-from-within-an-oban-worker/58277](https://elixirforum.com/t/spawning-task-vs-enqueuing-another-oban-worker-from-within-an-oban-worker/58277)  
132. Using Oban on functions that return \- Elixir Forum, accessed November 17, 2025, [https://elixirforum.com/t/using-oban-on-functions-that-return/29283](https://elixirforum.com/t/using-oban-on-functions-that-return/29283)  
133. Understanding GenServer in Elixir: A Flexible Way to Manage State | by rizan \- Medium, accessed November 17, 2025, [https://medium.com/@qrizan/understanding-genserver-in-elixir-a-flexible-way-to-manage-state-1379ac382eef](https://medium.com/@qrizan/understanding-genserver-in-elixir-a-flexible-way-to-manage-state-1379ac382eef)  
134. Is GenServer used in real life applications? If so, how? \- Elixir Forum, accessed November 17, 2025, [https://elixirforum.com/t/is-genserver-used-in-real-life-applications-if-so-how/32668](https://elixirforum.com/t/is-genserver-used-in-real-life-applications-if-so-how/32668)  
135. Extracting Microservices in Phoenix app : Genserver \- Stack Overflow, accessed November 17, 2025, [https://stackoverflow.com/questions/35726303/extracting-microservices-in-phoenix-app-genserver](https://stackoverflow.com/questions/35726303/extracting-microservices-in-phoenix-app-genserver)  
136. Managing Distributed State with GenServers in Phoenix and Elixir | AppSignal Blog, accessed November 17, 2025, [https://blog.appsignal.com/2024/10/29/managing-distributed-state-with-genservers-in-phoenix-and-elixir.html](https://blog.appsignal.com/2024/10/29/managing-distributed-state-with-genservers-in-phoenix-and-elixir.html)  
137. RPC over RabbitMQ (with Elixir) \- Andrea Leopardi, accessed November 17, 2025, [https://andrealeopardi.com/posts/rpc-over-rabbitmq-with-elixir/](https://andrealeopardi.com/posts/rpc-over-rabbitmq-with-elixir/)
