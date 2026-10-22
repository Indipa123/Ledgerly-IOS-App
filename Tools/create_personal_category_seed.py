"""Generate the empty updatable Core ML model. No private training data is used."""
from pathlib import Path
from coremltools.models.nearest_neighbors import KNearestNeighborsClassifierBuilder
from coremltools.models.utils import save_spec

builder = KNearestNeighborsClassifierBuilder(
    input_name="features", output_name="category", number_of_dimensions=512,
    default_class_label="unknown", number_of_neighbors=3,
    weighting_scheme="inverse_distance", index_type="linear",
)
builder.author = "Ledgerly"
builder.description = "Empty on-device personal category model; 512 stable hashed character features."
assert builder.is_updatable
output = Path(__file__).resolve().parents[1] / "Ledgerly IOS App/Ledgerly IOS App/Assets/PersonalCategorySeed.mlmodel"
save_spec(builder.spec, str(output))
print(f"Wrote empty updatable model: {output.name}")
