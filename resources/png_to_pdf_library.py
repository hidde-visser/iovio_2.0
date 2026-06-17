import img2pdf
import os
from robot.api import logger

class png_to_pdf_library:

    def convert_png_to_pdf(self, png_path, pdf_path):
        """Converts a PNG file to a PDF file.

        Args:
            png_path: Full path to the source PNG file.
            pdf_path: Full path where the output PDF will be saved.
        """
        if not os.path.exists(png_path):
            raise FileNotFoundError(f"PNG file not found: {png_path}")

        with open(pdf_path, "wb") as pdf_file:
            pdf_file.write(img2pdf.convert(png_path))

        logger.info(f"Successfully converted {png_path} to {pdf_path}")