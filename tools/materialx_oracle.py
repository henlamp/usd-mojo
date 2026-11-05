"""Independent MaterialX Python reference, run in its own interpreter."""

import json, sys
from pathlib import Path
import MaterialX as mx
from MaterialX import (
    PyMaterialXGenShader as gen,
    PyMaterialXGenMsl as msl,
    PyMaterialXGenGlsl as glsl,
)

source, prefix, destination = sys.argv[1:4]
element = sys.argv[4] if len(sys.argv) > 4 else "out"
search = mx.FileSearchPath(prefix)
search.append(str(Path(source).parent))
standard = mx.createDocument()
mx.loadLibraries(["libraries"], search, standard)
doc = mx.createDocument()
mx.readFromXmlFile(doc, source, search)
doc.setDataLibrary(standard)
valid, message = doc.validate()
assert valid, message
result = {
    "version": mx.getVersionString(),
    "renderables": [x.getNamePath() for x in gen.findRenderableElements(doc)],
}
for target, implementation in [
    ("msl", msl.MslShaderGenerator),
    ("glsl", glsl.GlslShaderGenerator),
]:
    generator = implementation.create()
    context = gen.GenContext(generator)
    context.registerSourceCodeSearchPath(search)
    shader = generator.generate(
        "usd_mojo_material", doc.getDescendant(element), context
    )
    result[target] = shader.getStage("pixel").getSourceCode()
Path(destination).write_text(json.dumps(result, indent=2) + "\n")
