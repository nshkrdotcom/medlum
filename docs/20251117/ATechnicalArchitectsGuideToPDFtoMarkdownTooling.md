### **I. Executive Analysis: A Technical Architect's Guide to PDF-to-Markdown Tooling**

This report presents a comprehensive technical due diligence analysis of Python-based libraries for converting PDF documents into structured Markdown. The evaluation focuses on libraries that are "well-vetted" and "plug-and-play," supporting both CLI and Python API access, with an emphasis on solutions leveraging AI/LLM technology.

A thorough investigation reveals that the user's primary requirements are in direct and significant conflict. The selection of a PDF-to-Markdown library is not a simple choice for the "best" tool, but rather a critical systems-level trade-off between three competing factors: **(A) Conversion Quality, (B) Licensing Risk, and (C) System Complexity.** No single solution examined excels in all three dimensions.

The most profound conflict exists between the "well-vetted" requirement and the highest-performing libraries. For a technical architect, "well-vetted" must include legal and licensing verification for proprietary commercial use. This analysis found that the two most powerful and frequently cited libraries carry "viral" copyleft licenses that render them unusable for most commercial applications without a separate, paid license.

* **PyMuPDF (PyMuPDF4LLM)**: This is the fastest and most reliable *non-AI* solution, offering a superb balance of speed and quality.1 However, its "well-vetted" status is **negated** by its **GNU AGPL v3.0 license**.3 As confirmed by community analysis, this makes the library "almost unusable... without paying" 4, as any networked application using it would be required to release its entire source code.  
* **Marker (marker-pdf)**: This is arguably the highest-quality *AI-driven* solution, demonstrating "perfect structure preservation".1 However, its "well-vetted" status is **negated** by a dual-license trap: the codebase is **GPL v3.0**, and the model weights are under a commercially-restrictive **AI Pubs Open Rail-M** license, forbidding use by companies with over $2M in funding or revenue.5

A secondary conflict exists between the "plug-and-play" requirement and the use of "AI/LLM" models.

* "AI/LLM" tools (Docling, Marker, Nougat) are fundamentally *not* "plug-and-play." They require multi-gigabyte model downloads, extensive and heavy dependency chains 6, and significant hardware (e.g., GPU/VRAM) to run effectively.5  
* "Plug-and-play" tools, defined by their lightweight and minimal-dependency nature (e.g., Kreuzberg, PyMuPDF), are orders of magnitude faster but lack the deep semantic understanding of their AI-driven counterparts.1

Based on these findings, this report's strategic recommendations are bifurcated by the primary, non-negotiable constraint: software licensing.

* **For Enterprise / Proprietary Commercial Use:** The viable options are restricted to permissively-licensed tools. The primary contenders are **Unstructured.io (Apache 2.0)** 8 and **Docling (MIT)**.9 The selection between them is a choice between a flexible *partitioning framework* that provides a list of semantic elements (Unstructured) versus a heavyweight, end-to-end *converter* that directly outputs Markdown (Docling).  
* **For Open-Source / Academic / Personal Use:** Where AGPL/GPL licensing is not a constraint, **Marker** 5 offers the highest conversion quality.1 **PyMuPDF4LLM** 3 offers the maximum speed and an excellent quality-to-speed ratio.1 **Nougat** 11 is the premier choice *only* for academic documents containing complex mathematical notation.12

The premise of a single tool that is simultaneously lightweight, legally permissive for all commercial use, and provides state-of-the-art AI-driven conversion quality is flawed. The true task is to identify the *correct* tool for a specific organizational context, defined by licensing tolerance and hardware budget.

### **II. The Conversion Landscape: A Taxonomy of Modern Ingestion Tools**

To navigate the market, it is essential to categorize the available tools by their underlying technology. This architecture dictates their performance, cost, and output quality.

#### **Category 1: Heuristic & Rule-Based Parsers**

These tools operate by parsing the internal structure of the PDF. As noted in developer forums, the PDF is a "terrible format" for data extraction; it is not a logical document but a set of instructions for placing text and lines at specific coordinates.13 Heuristic parsers use rules based on font sizes, X/Y coordinates, and text blocks to reconstruct the logical reading order.

* **Primary Example: PyMuPDF4LLM**  
  * **Technology:** PyMuPDF is a high-performance Python binding for the mature MuPDF library, written in C.3 PyMuPDF4LLM is a specific module built on this foundation, explicitly "aimed to make it easier to extract PDF content... for LLM & RAG environments".14  
  * **Value Proposition:** It is not a simple text-scraper. It is designed to produce structured, GitHub-compatible Markdown. It identifies header lines via font size (prefixing them with \# tags), detects bold/italic/mono-spaced text, and formats ordered/unordered lists and code blocks.14 It also detects tables and integrates them into the Markdown output.3  
  * **Performance:** Its primary advantage is speed. Benchmarks show it is orders of magnitude faster than AI-driven tools, processing a test document in 0.12 seconds versus 11.3 seconds for Marker.1  
  * **Limitation:** As a non-AI tool, its heuristic-based approach is inherently brittle. It can be easily confused by complex multi-column layouts or tables that do not have clean, discernible structures.13

#### **Category 2: AI-Driven Layout Models (The "Modern" Standard)**

These tools represent the modern standard for document intelligence. They use deep learning models, often computer vision-based, to analyze the *rendered image* of the page. This allows them to identify logical layout elements (titles, paragraphs, tables, images) and determine the correct reading order, even in complex, multi-column formats.

* **Primary Examples: Marker, Docling, Unstructured.io**  
  * **Marker**: Employs a pipeline of deep learning models for text extraction, layout detection (using the surya model), artifact removal, and post-processing.16  
  * **Docling**: Uses a default layout model named "Heron" and a suite of specialized models to understand table structure, code blocks, and mathematical formulas.17  
  * **Unstructured.io**: Uses layout-parser models to "partition" the document into a list of semantic elements, which are classified blocks like Title, NarrativeText, or Table.8

#### **Category 3: End-to-End Vision Transformers (The "Specialists")**

This category consists of single, large transformer models that are trained end-to-end on the conversion task. They take raw document *pixels* as input and generate a structured text *markup* as their direct output.

* **Primary Example: Nougat (Meta AI)**  
  * **Technology:** Nougat (Neural Optical Understanding for Academic Documents) is a Vision Transformer model utilizing a Swin Transformer vision encoder and an mBART-based text decoder.12  
  * **Value Proposition:** It is a specialist tool purpose-built for "academic documents".21 Its primary, unique strength is converting complex **mathematical expressions and LaTeX** into a machine-readable markup format, bridging the gap between human-readable scientific papers and machine-readable text.12  
  * **Limitation:** Because it is a specialist, it is trained almost exclusively on academic papers.23 Benchmarks show that while it excels on arXiv papers, it can perform worse than Marker on non-academic texts.24

#### **Category 4: LLM-Enhanced Hybrid Systems**

This emerging category represents the current state-of-the-art for quality. It uses an AI model (Category 2\) for the initial, high-speed parsing and layout detection, and then pipes that structured output to a general-purpose Large Language Model (LLM) (e.g., GPT-4, Gemini, or a local Ollama model) for a final "cleanup" and semantic structuring pass.

* **Primary Example: Marker (Hybrid Mode)**  
  * **Technology:** Marker provides a \--use\_llm flag that engages a configured LLM backend (supporting Gemini or any Ollama model).5  
  * **Value Proposition:** The LLM provides a layer of semantic understanding that the vision models lack. It can perform complex tasks that are impossible for the parser alone, such as the ability to "merge tables across pages, handle inline math, \[and\] format tables properly".5 Benchmarks confirm this hybrid mode provides the absolute highest accuracy, particularly for complex tables.5  
  * **Limitation:** This approach adds significant latency, cost (if using a paid API), and a major new dependency (a running LLM, either local or remote).

### **III. In-Depth Tooling Analysis: The Primary Contenders**

This section provides a detailed analysis of the six primary libraries that match the user's query, focusing on the critical factors of features, implementation, and licensing.

#### **1\. PyMuPDF (and PyMuPDF4LLM)**

* Technical & Feature Deep Dive:  
  PyMuPDF is the Python binding for MuPDF, a mature, high-performance C-based document library.3 The PyMuPDF4LLM package is a specialized, high-level wrapper built specifically to "extract PDF content... for LLM & RAG environments".14 It directly addresses the user's need for structured output by converting text and tables into a unified, GitHub-compatible Markdown string.14 Its heuristic engine identifies structural elements based on formatting: headers are detected via font size, and bold, italic, mono-spaced, list, and code block elements are formatted accordingly.14 It also features robust table extraction.3 Benchmarks praise its "excellent markdown output" and "great balance of speed and quality".1 This is reinforced by community consensus, which describes its output as a "nice structured extract" 2 and ranks it as "better than PDFplumber , PyPDF2, and others" for this purpose.2  
* Implementation: API and CLI Usage:  
  This library perfectly matches the user's request for dual-mode operation.  
  * **Python API:** It is designed to be imported as a Python module, allowing developers to integrate its conversion logic directly into their applications.14  
  * CLI: The PyMuPDF4LLM module can also be invoked as a standalone command-line script, enabling batch processing or simple shell-based workflows.15 A typical invocation is:  
    $ python pymupdf\_rag.py input.pdf  
* Critical Vetting: The AGPL License Implications:  
  This is the most critical vetting failure for this tool.  
  * **License:** PyMuPDF is licensed under the **GNU AGPL v3.0**.3  
  * **Analysis:** The AGPL is a "viral" copyleft license. Its terms require that any software that links to the library and is *made available over a network* (e.g., a SaaS application, a RAG API) must have its *entire source code* made available to all users under the same AGPL license. This is a "trap" for unwary developers; as one user noted, PyMuPDF has "top notch performance but also an AGPL license, and is almost unusable because of this without paying".4  
  * **Conclusion:** This licensing makes PyMuPDF completely non-viable for any proprietary commercial project. To use it in such a context, a commercial license must be purchased from Artifex, the exclusive licensing agent.3

#### **2\. Marker (DataLab)**

* Technical & Feature Deep Dive:  
  Marker is a sophisticated, end-to-end deep learning pipeline.16 It is a multi-format converter, ingesting PDF, image, DOCX, XLSX, EPUB, and HTML, and outputting Markdown, JSON, or HTML.5 Its feature set is extensive, designed to handle the most complex documents. It formats tables, forms, equations (as LaTeX), inline math, links, and code blocks.5 It also intelligently removes artifacts like page headers and footers.5 Its flagship feature is the "Hybrid Mode" (--use\_llm), which leverages an external LLM to semantically clean the output, enabling it to merge tables that span multiple pages.5 Benchmarks confirm its "perfect structure preservation" 1, but this quality comes at the cost of speed (11.3s in one test).1 It is, however, benchmarked as approximately 10x faster than Nougat.25  
* Implementation: API and CLI Usage:  
  Marker also perfectly satisfies the user's interface requirements.  
  * **Python API:** It provides a clean, high-level PdfConverter class, making it simple to integrate into a Python application.5  
    Python  
    from marker.converters.pdf import PdfConverter  
    from marker.models import create\_model\_dict

    converter \= PdfConverter(  
        artifact\_dict=create\_model\_dict(),  
    )  
    rendered \= converter("FILEPATH")  
    \# rendered.markdown contains the output string

  * CLI: It provides a robust CLI for both single files (marker\_single) and batch processing (marker).5  
    $ marker\_single /path/to/file.pdf \--output\_dir./md\_out  
* Critical Vetting: The GPL & Rail-M License Implications:  
  Marker presents a dual-license "trap" that makes it non-viable for most commercial use.  
  * **License:**  
    1. **Code License:** The codebase is licensed under **GPL-3.0**.5  
    2. **Model License:** The model weights use a modified **AI Pubs Open Rail-M** license.5  
  * **Analysis:** The GPL-3.0 license is viral for any *distributed* software, similar to the AGPL. More restrictively, the Rail-M license is a *commercial* restriction. It explicitly states the models are "free for research, personal use, and startups under $2M funding/revenue".5  
  * **Conclusion:** This tool is explicitly *not* free for any established company. It is a "freemium" model designed to drive adoption of the paid "managed API or on-prem document intelligence solution".5 It is not "well-vetted" for commercial use.

#### **3\. Nougat (Meta AI)**

* Technical & Feature Deep Dive:  
  Nougat (Neural Optical Understanding for Academic Documents) is a specialized Vision Transformer model developed by Meta AI.12 It is not a general-purpose converter. It was explicitly trained on scientific documents from arXiv and PMC.23 Its unique, declared capability is the end-to-end transcription of raw PDF pixels into a Mathpix-compatible Markdown format, with a deep understanding of complex LaTeX math and tables.12 It is designed to "make scientific knowledge more accessible".22 Its capabilities are limited to English-language papers; other languages, especially non-Latin ones, "will not work".23  
* Implementation: API and CLI Usage:  
  This is the library's primary failure against the user's requirements.  
  * CLI: It provides a functional nougat command-line tool 23:  
    $ nougat path/to/file.pdf \-o output\_directory  
  * **Python API:** Nougat is *not* designed to be used as a simple, importable Python library. The nougat\_api command starts a **web server**.23 To use it from a Python script, the developer must run this server as a separate process and make an HTTP POST request to it. This is confirmed by community discussions, which state it is "meant to be run from the command line" or via its API.27  
  * **Conclusion:** This architecture fails the user's "plug and play... python API" requirement for a simple, importable module.  
* **Critical Vetting: The MIT License:**  
  * **License:** **MIT License**.11  
  * **Analysis:** Nougat is truly open-source and permissively licensed. There are no commercial or copyleft restrictions.  
  * **Conclusion:** It is an excellent, "well-vetted" choice *if and only if* the user's domain is purely academic/scientific and the server-based API architecture is acceptable.

#### **4\. Unstructured.io**

* Technical & Feature Deep Dive:  
  The unstructured library is a comprehensive set of "open-source components for ingesting and pre-processing" documents, designed specifically for LLM workflows.8 Its core philosophy is different from other tools. Its main function is "partitioning," not direct conversion.19 It breaks a raw document down into a List\[Element\], where each element is a classified semantic block (e.g., Title, NarrativeText, ListItem, Table).19 This element-based approach is its primary strength, as it gives the developer granular control to filter, modify, or route specific elements before final structuring.20 It supports a vast array of formats, including PDF, HTML, DOCX, PPTX, and EML.19 Markdown conversion is a secondary feature; a recent commit (feat: convert elements to markdown 8\) indicates this is being added as a more first-class function, but the core design remains element-centric.  
* **Implementation: API and CLI Usage:**  
  * **Python API:** The API is clean, robust, and revolves around the partition function.8  
    Python  
    from unstructured.partition.auto import partition  
    elements \= partition("example-docs/layout-parser-paper.pdf")  
    \# 'elements' is a List\[Element\]  
    \# Developer must now iterate this list to build Markdown

  * **CLI:** A command-line interface is available via the unstructured-ingest package.30  
* **Critical Vetting: The Apache 2.0 License:**  
  * **License:** **Apache-2.0 License**.8  
  * **Analysis:** This is a fully permissive, patent-respecting, enterprise-friendly license. It is "well-vetted" for all use cases, including proprietary commercial products.  
  * **Conclusion:** Unstructured is a *framework for building an ingestion pipeline*, not a "plug and play" *converter*. This makes it more powerful and flexible than the other tools but also less "plug and play," as it requires an extra development step to transform the partitioned elements into the final Markdown string.

#### **5\. Docling (IBM)**

* Technical & Feature Deep Dive:  
  Docling is an "open-source... document conversion tool" developed by IBM Research.10 It is positioned as a direct, permissively-licensed, and enterprise-grade competitor to tools like Marker. It provides "Advanced PDF understanding," including page layout, reading order, table structure, code, and formulas.17 It is a true multi-format converter, outputting to Markdown, HTML, and lossless JSON.17  
* Implementation: API and CLI Usage:  
  Docling perfectly matches the user's interface requirements, offering a clean, high-level API.  
  * **Python API:** It provides a DocumentConverter class that is simple and direct.17  
    Python  
    from docling.document\_converter import DocumentConverter   
    source \= "https://arxiv.org/pdf/2408.09869"  
    converter \= DocumentConverter()   
    result \= converter.convert(source)   
    print(result.document.export\_to\_markdown())

  * CLI: It provides a straightforward docling CLI command.17  
    $ docling https://arxiv.org/pdf/2206.01062  
* **Critical Vetting: The MIT License & Install Footprint:**  
  * **License:** **MIT License**.9  
  * **Analysis:** This is a fully permissive license, making Docling "well-vetted" for all commercial use. This combination of permissive license, AI-driven quality, and a direct-conversion API makes it a top contender.  
  * **Conclusion (The "Heavyweight" Contender):** The primary trade-off for Docling is its system complexity. It is not "plug-and-play" in a lightweight sense. Benchmarks of its installation footprint show it is a massive, "heavyweight" solution, requiring **1,032MB (over 1GB)** of disk space and **88 dependencies**.6 This makes it difficult to deploy in resource-constrained environments like serverless functions or lightweight Docker containers.

#### **6\. Kreuzberg**

* Technical & Feature Deep Dive:  
  Kreuzberg is a "document intelligence framework" 35 that takes a different approach. It is not a monolithic AI model. Instead, it is a "modern Python library" 36 that serves as a clean, unified wrapper around a set of other powerful, permissively-licensed tools: Pandoc, PDFium, and Tesseract.35 Its value proposition is a simple, modern API (with both async and sync support) 36 and resource-efficient local processing (no GPU required).38 It explicitly supports table extraction.38  
* Implementation: API and CLI Usage:  
  This library matches the user's interface requirements.  
  * **Python API:** Provides both async and sync APIs for modern Python applications.37  
  * **CLI:** Provides a CLI for batch processing and automation.35  
* **Critical Vetting: The MIT License & Output Format:**  
  * **License:** **MIT License**.35  
  * **Analysis:** Kreuzberg is fully permissive and "well-vetted" for all commercial use.  
  * **Conclusion (The "Modern Wrapper"):** The documentation lists Markdown as a supported *input* format.35 Its primary function is to "Extract text, metadata, and structured data".35 While it uses Pandoc, its capabilities as a direct *PDF-to-structured-Markdown* converter are less explicitly benchmarked than the other tools. Its primary advantage is its "plug-and-play" nature: it is extremely lightweight, with an installation size of only **71MB**.6 It is the ideal permissively-licensed, lightweight alternative to PyMuPDF.

### **IV. Implementation & Usability: A "Plug-and-Play" Reality Check**

A direct, side-by-side comparison of the developer experience highlights the practical trade-offs.

#### **Table 1: Installation & Dependency Footprint**

This table provides a quantitative answer to the "plug-and-play" requirement. A 1GB+ installation with 88 dependencies is not "plug-and-play" and has significant implications for deployment, CI/CD pipeline speed, and container image size.

| Library | pip install Command | License | Est. Install Size | Key Dependencies |
| :---- | :---- | :---- | :---- | :---- |
| **PyMuPDF4LLM** | pip install pymupdf4llm 14 | **AGPL 3.0** 3 | \~30-50MB | PyMuPDF |
| **Marker** | pip install marker-pdf 5 | **GPL 3.0** (Code) 5 | \>500MB | pytorch, surya 16, 3.5GB+ VRAM 5 |
| **Nougat** | pip install nougat-ocr 23 | **MIT** 11 | \>500MB | pytorch, timm |
| **Unstructured** | pip install "unstructured\[all-docs\]" 8 | **Apache 2.0** 8 | **\~146MB** 6 | poppler-utils, tesseract (system) 8 |
| **Docling** | pip install docling 17 | **MIT** 9 | **\~1,032MB (1GB+)** 6 | 88 dependencies 6 |
| **Kreuzberg** | pip install kreuzberg 35 | **MIT** 35 | **\~71MB** 6 | pandoc, pdfium, tesseract 35 |

#### **Table 2: Python API Canonical Usage**

This table compares the API design. The most "plug-and-play" API for *direct conversion* belongs to Docling and Marker. Unstructured offers a simple API for *partitioning*, which requires an extra step. Nougat fails the simple API test.

| Library | Python API Example |
| :---- | :---- |
| **PyMuPDF4LLM** | import pymupdf4llm md\_text \= pymupdf4llm.to\_markdown(doc, pages=...) (Inferred from 14) |
| **Marker** | from marker.converters.pdf import PdfConverter converter \= PdfConverter() rendered \= converter("file.pdf") md\_text \= rendered.markdown (Source: 5) |
| **Nougat** | **Not possible as a simple import.** Requires starting a server (nougat\_api) and using requests.post('http://127.0.0.1:8503/predict/',...) (Source: 23) |
| **Unstructured** | from unstructured.partition.pdf import partition\_pdf elements \= partition\_pdf("file.pdf") \# User must now iterate 'elements' to build markdown (Source: 19) |
| **Docling** | from docling.document\_converter import DocumentConverter converter \= DocumentConverter() result \= converter.convert("file.pdf") md\_text \= result.document.export\_to\_markdown() (Source: 17) |

This API comparison reveals a clear divide. Marker and Docling 5 offer the most direct, object-oriented APIs that map 1-to-1 with the user's request for a *converter*. Unstructured 19 provides a simple API for *partitioning*, which is a prerequisite step to conversion. Nougat 23 is designed as a service, not a library, failing this requirement.

### **V. Head-to-Head Qualitative Benchmarking**

The final evaluation criterion is the *quality* of the structured Markdown output.

#### **Structural Fidelity & Reading Order**

This is the most fundamental challenge, as the library must reconstruct a logical document from a "terrible format".13

* **PyMuPDF4LLM**: Praised in benchmarks for its "excellent markdown output" 1 and "nice structured extract".2 Its heuristic approach of using font sizes to identify headers is fast and effective for simple documents.14  
* **Marker**: Considered best-in-class, with benchmarks citing "Perfect structure preservation".1 Its deep learning layout analysis 16 is more robust than heuristics for complex, multi-column layouts.  
* **Unstructured**: Its entire purpose is to preserve structure, but as *semantic elements* (Title, ListItem).19 This is arguably the most *semantically* robust partitioning, as the output is a structured list of classified objects, not a single text string.  
* **Docling**: Also a top performer. Benchmarks praise its "superior table structure preservation, and effective ToC reconstruction".39

#### **Complex Element Handling: Tables**

Tables are a notorious failure point for PDF extraction.13

* **Specialist Tools:** While not end-to-end converters, libraries like pdfplumber 1, Camelot 40, and Tabula 40 are often cited as excellent *table-only* extractors.  
* **End-to-End Tools:**  
  * **PyMuPDF4LLM**: Detects and converts tables as part of its standard Markdown conversion.3  
  * **Marker**: A top performer. Its baseline model formats tables.5 Its **hybrid LLM mode (--use\_llm)** 5 is specifically designed to "merge tables across pages" and "format tables properly".5 A benchmark comparing marker, gemini flash alone, and marker with use\_llm shows the hybrid mode has the highest table accuracy.5  
  * **Docling**: A strong contender, using a dedicated AI model for "table structure recognition" as part of its pipeline.17

#### **Complex Element Handling: Equations & Code Blocks**

This is a critical requirement for technical and scientific documents.

* **Nougat**: This is Nougat's sole purpose. It is designed to "transcribe scientific PDFs" and "understands LaTeX math".12 It is the undisputed specialist for this task.  
* **Marker**: A strong generalist. It "converts most equations to latex" and "formats code blocks" as part of its standard conversion.5  
* **Docling**: Also explicitly claims to handle "code" and "formulas".17

#### **Performance & Speed**

The trade-off between conversion quality and latency is non-negotiable.

* A 2025 benchmark 1 provides a perfect linear illustration of this "quality vs. time" trade-off:  
  * pypdfium2 (0.003s) \-\> "clean basic text, no structure"  
  * pypdf (0.024s) \-\> "occasional spacing artifacts"  
  * pdfplumber (0.10s) \-\> "Good for tables, text needs configuration"  
  * **pymupdf4llm (0.12s)** \-\> **"Excellent markdown output, great balance"**  
  * **unstructured (1.29s)** \-\> "Clean semantic chunks" (AI-assisted)  
  * **marker-pdf (11.3s)** \-\> **"Perfect structure preservation"** (Full AI)  
* This data clearly demonstrates that structural quality is computationally expensive. PyMuPDF4LLM is the clear winner for *speed-at-quality*, while Marker is the winner for *absolute quality*.  
* Further benchmarks confirm this, noting Marker is approximately 10x faster than Nougat (processing at 0.3 seconds/page vs. 3.0 seconds/page).26  
* Docling is noted for "moderate and predictable processing speeds," scaling linearly.39

### **VI. Strategic Recommendations & Decision Matrix**

This final section provides actionable conclusions based on the primary, non-negotiable constraint for any technical architect: software licensing.

#### **The Licensing Gauntlet: A Non-Negotiable Decision Point**

The "well-vetted" requirement must be interpreted as "legally vetted for proprietary commercial use." Under this interpretation, most of the popular, high-performance tools fail.

* **AGPL v3.0 (PyMuPDF)**: If your Python code imports this library and is used to power any *networked service* (e.g., an internal RAG API, a public-facing SaaS product), your *entire application's source code* must be publicly released under the AGPL.3 This is a non-starter for 99% of commercial products.4  
* **GPL v3.0 (Marker Code)**: If you *distribute* your application (e.g., in a Docker container, as an on-prem appliance) that includes the Marker library, your entire application must be licensed under the GPL.5 This is also a non-starter for most proprietary products.  
* **AI Pubs Open Rail-M (Marker Model)**: This is a *commercial restriction*, not a copyleft license. It explicitly *forbids* use by any company with \>$2M in funding or revenue.5 This is a legal "time bomb" for a successful startup.  
* **Apache 2.0 / MIT (Unstructured, Docling, Nougat, Kreuzberg)**: These are the *only* truly "well-vetted" licenses for any use case. They are permissive, require only attribution, and carry no "viral" (copyleft) obligations or commercial restrictions.8

#### **Table 3: Strategic Decision Matrix**

The final recommendation is not one tool, but a decision matrix based on organizational context.

| Use Case | Primary Recommendation | Rationale & Key Evidence | Licensing & "Plug-and-Play" Caveats |
| :---- | :---- | :---- | :---- |
| **1\. Enterprise RAG Pipeline (Proprietary / Commercial)** | **Unstructured.io** or **Docling** | These are the *only* powerful, AI-driven tools with permissive, enterprise-safe licenses.8 Docling provides direct Markdown conversion.17 Unstructured offers a more flexible partitioning framework.19 | **Apache 2.0 / MIT.** Both are "heavyweight." Docling has a \>1GB install.6 Unstructured requires an extra dev step to convert its List\[Element\] output to Markdown.19 |
| **2\. Open-Source Project (GPL/AGPL-compatible)** | **Marker** | The copyleft license is acceptable in this context. Offers the highest quality ("Perfect structure preservation") 1 and best-in-class table/math handling via its LLM-hybrid mode.5 | **GPL 3.0.** Not "plug-and-play." Requires GPU and significant VRAM for good performance.5 Heavy dependencies. |
| **3\. Academic / Scientific Research** | **Nougat** | **MIT License**.11 Purpose-built by Meta AI for converting scientific papers, especially LaTeX math, for which it is the undisputed specialist.12 | **MIT License.** Fails the Python API requirement; it is a *service* that must be run and called via HTTP.23 Performs poorly on non-academic documents.24 |
| **4\. High-Speed, Low-Resource (Serverless / CLI Tool)** | **Kreuzberg** or **PyMuPDF4LLM** | Both are extremely fast and lightweight. Kreuzberg (71MB6) has a permissive **MIT license**.35 PyMuPDF4LLM (0.12s1) has benchmark-proven "excellent markdown output".1 | **CRITICAL LICENSE CONFLICT:** PyMuPDF4LLM is **AGPL** 3 and unusable for most. Kreuzberg (MIT) is the safe choice, though its Markdown *output quality* is less vetted by benchmarks. |

#### **Works cited**

1. I Tested 7 Python PDF Extractors So You Don't Have To (2025 Edition) \- Aman Kumar, accessed November 17, 2025, [https://onlyoneaman.medium.com/i-tested-7-python-pdf-extractors-so-you-dont-have-to-2025-edition-c88013922257](https://onlyoneaman.medium.com/i-tested-7-python-pdf-extractors-so-you-dont-have-to-2025-edition-c88013922257)  
2. What's the Best Python Library for Extracting Text from PDFs? : r/LangChain \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/LangChain/comments/1e7cntq/whats\_the\_best\_python\_library\_for\_extracting\_text/](https://www.reddit.com/r/LangChain/comments/1e7cntq/whats_the_best_python_library_for_extracting_text/)  
3. Features Comparison \- PyMuPDF documentation, accessed November 17, 2025, [https://pymupdf.readthedocs.io/en/latest/about.html](https://pymupdf.readthedocs.io/en/latest/about.html)  
4. So, for PDF we need to distinguish between two types of text extraction, accessed November 17, 2025, [https://news.ycombinator.com/item?id=43057663](https://news.ycombinator.com/item?id=43057663)  
5. datalab-to/marker: Convert PDF to markdown \+ JSON ... \- GitHub, accessed November 17, 2025, [https://github.com/datalab-to/marker](https://github.com/datalab-to/marker)  
6. I benchmarked 4 Python text extraction libraries so you don't have to (2025 results) \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/Python/comments/1ls6hj5/i\_benchmarked\_4\_python\_text\_extraction\_libraries/](https://www.reddit.com/r/Python/comments/1ls6hj5/i_benchmarked_4_python_text_extraction_libraries/)  
7. I benchmarked 4 Python text extraction libraries so you don't have to (2025 results) \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/LLMDevs/comments/1ls6i3t/i\_benchmarked\_4\_python\_text\_extraction\_libraries/](https://www.reddit.com/r/LLMDevs/comments/1ls6i3t/i_benchmarked_4_python_text_extraction_libraries/)  
8. Unstructured-IO/unstructured: Convert documents to ... \- GitHub, accessed November 17, 2025, [https://github.com/Unstructured-IO/unstructured](https://github.com/Unstructured-IO/unstructured)  
9. docling-project/docling-core: A python library to define and validate data types in Docling., accessed November 17, 2025, [https://github.com/docling-project/docling-core](https://github.com/docling-project/docling-core)  
10. A new tool to unlock data from enterprise documents for generative AI \- IBM Research, accessed November 17, 2025, [https://research.ibm.com/blog/docling-generative-AI](https://research.ibm.com/blog/docling-generative-AI)  
11. nougat-ocr \- PyPI, accessed November 17, 2025, [https://pypi.org/project/nougat-ocr/](https://pypi.org/project/nougat-ocr/)  
12. Nougat is a Meta AI's revolutionary OCR model designed to transcribe scientific PDFs into an easy-to-use Markdown format. \- GitHub, accessed November 17, 2025, [https://github.com/inuwamobarak/nougat](https://github.com/inuwamobarak/nougat)  
13. Looking for a Python module to convert PDF to Markdown while retaining structure (headings, subheadings, nested tables) \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/AskProgramming/comments/1em67a7/looking\_for\_a\_python\_module\_to\_convert\_pdf\_to/](https://www.reddit.com/r/AskProgramming/comments/1em67a7/looking_for_a_python_module_to_convert_pdf_to/)  
14. PyMuPDF4LLM \- PyMuPDF documentation, accessed November 17, 2025, [https://pymupdf.readthedocs.io/en/latest/pymupdf4llm/](https://pymupdf.readthedocs.io/en/latest/pymupdf4llm/)  
15. RAG/LLM and PDF: Conversion to Markdown Text with PyMuPDF | Medium, accessed November 17, 2025, [https://medium.com/@pymupdf/rag-llm-and-pdf-conversion-to-markdown-text-with-pymupdf-03af00259b5d](https://medium.com/@pymupdf/rag-llm-and-pdf-conversion-to-markdown-text-with-pymupdf-03af00259b5d)  
16. pip install marker-pdf==0.3.2 \- PyPI, accessed November 17, 2025, [https://pypi.org/project/marker-pdf/0.3.2/](https://pypi.org/project/marker-pdf/0.3.2/)  
17. docling-project/docling: Get your documents ready for gen AI \- GitHub, accessed November 17, 2025, [https://github.com/docling-project/docling](https://github.com/docling-project/docling)  
18. Which PDF Parser Should You Use? Comparing Docling, Marker, MinerU, olmOCR \- and Why NetMind ParsePro Might Be Better, accessed November 17, 2025, [https://blog.netmind.ai/article/Which\_PDF\_Parser\_Should\_You\_Use%3F\_Comparing\_Docling%2C\_Marker%2C\_MinerU%2C\_olmOCR\_-\_and\_Why\_NetMind\_ParsePro\_Might\_Be\_Better](https://blog.netmind.ai/article/Which_PDF_Parser_Should_You_Use%3F_Comparing_Docling%2C_Marker%2C_MinerU%2C_olmOCR_-_and_Why_NetMind_ParsePro_Might_Be_Better)  
19. Partitioning \- Unstructured, accessed November 17, 2025, [https://docs.unstructured.io/open-source/core-functionality/partitioning](https://docs.unstructured.io/open-source/core-functionality/partitioning)  
20. How to Parse a PDF, Part 1 \- Unstructured, accessed November 17, 2025, [https://unstructured.io/blog/how-to-parse-a-pdf-part-1](https://unstructured.io/blog/how-to-parse-a-pdf-part-1)  
21. facebook/nougat-base \- Hugging Face, accessed November 17, 2025, [https://huggingface.co/facebook/nougat-base](https://huggingface.co/facebook/nougat-base)  
22. Nougat, accessed November 17, 2025, [https://facebookresearch.github.io/nougat/](https://facebookresearch.github.io/nougat/)  
23. facebookresearch/nougat: Implementation of Nougat ... \- GitHub, accessed November 17, 2025, [https://github.com/facebookresearch/nougat](https://github.com/facebookresearch/nougat)  
24. samuell/marker-fork: Convert PDF to markdown quickly with high accuracy \- GitHub, accessed November 17, 2025, [https://github.com/samuell/marker-fork](https://github.com/samuell/marker-fork)  
25. cuuupid/cog-marker: Convert PDF to markdown quickly with high accuracy \- GitHub, accessed November 17, 2025, [https://github.com/cuuupid/cog-marker](https://github.com/cuuupid/cog-marker)  
26. Inside Marker: A Guided Source Code Tour for an AI-powered PDF Layout Detection Engine, accessed November 17, 2025, [https://journal.hexmos.com/marker-pdf-document-ai-2/](https://journal.hexmos.com/marker-pdf-document-ai-2/)  
27. Python: Using nougat-ocr in spyder \- Stack Overflow, accessed November 17, 2025, [https://stackoverflow.com/questions/77521397/python-using-nougat-ocr-in-spyder](https://stackoverflow.com/questions/77521397/python-using-nougat-ocr-in-spyder)  
28. nougat-ocr \- PyDigger, accessed November 17, 2025, [https://pydigger.com/pypi/nougat-ocr](https://pydigger.com/pypi/nougat-ocr)  
29. How to Process PDFs in Python: A Step-by-Step Guide | Unstructured, accessed November 17, 2025, [https://unstructured.io/blog/how-to-process-pdf-in-python](https://unstructured.io/blog/how-to-process-pdf-in-python)  
30. Examples \- Unstructured, accessed November 17, 2025, [https://docs.unstructured.io/open-source/how-to/examples](https://docs.unstructured.io/open-source/how-to/examples)  
31. Docling Technical Report \- arXiv, accessed November 17, 2025, [https://arxiv.org/html/2408.09869v5](https://arxiv.org/html/2408.09869v5)  
32. docling \- PyPI, accessed November 17, 2025, [https://pypi.org/project/docling/](https://pypi.org/project/docling/)  
33. Docling documentation \- GitHub Pages, accessed November 17, 2025, [https://docling-project.github.io/docling/](https://docling-project.github.io/docling/)  
34. docling-parse \- PyPI, accessed November 17, 2025, [https://pypi.org/project/docling-parse/](https://pypi.org/project/docling-parse/)  
35. Goldziher/kreuzberg: Document intelligence framework for ... \- GitHub, accessed November 17, 2025, [https://github.com/Goldziher/kreuzberg](https://github.com/Goldziher/kreuzberg)  
36. Show HN: Kreuzberg – Modern async Python library for document text extraction | Hacker News, accessed November 17, 2025, [https://news.ycombinator.com/item?id=43057375](https://news.ycombinator.com/item?id=43057375)  
37. Introducing Kreuzberg: A Simple, Modern Library for PDF and Document Text Extraction in Python \- Reddit, accessed November 17, 2025, [https://www.reddit.com/r/Python/comments/1if3axy/introducing\_kreuzberg\_a\_simple\_modern\_library\_for/](https://www.reddit.com/r/Python/comments/1if3axy/introducing_kreuzberg_a_simple_modern_library_for/)  
38. kreuzberg \- PyPI, accessed November 17, 2025, [https://pypi.org/project/kreuzberg/3.3.0/](https://pypi.org/project/kreuzberg/3.3.0/)  
39. PDF Data Extraction Benchmark 2025: Comparing Docling, Unstructured, and LlamaParse for Document Processing Pipelines \- Procycons, accessed November 17, 2025, [https://procycons.com/en/blogs/pdf-data-extraction-benchmark/](https://procycons.com/en/blogs/pdf-data-extraction-benchmark/)  
40. Python Libraries to Extract Tables From PDF: A Comparison \- Unstract, accessed November 17, 2025, [https://unstract.com/blog/extract-tables-from-pdf-python/](https://unstract.com/blog/extract-tables-from-pdf-python/)  
41. A Comparative Study of PDF Parsing Tools Across Diverse Document Categories \- arXiv, accessed November 17, 2025, [https://arxiv.org/html/2410.09871v1](https://arxiv.org/html/2410.09871v1)
