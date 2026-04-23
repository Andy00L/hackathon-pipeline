import { Inter } from "next/font/google";

/**
 * Single source of truth for font loading in the starter kit. Import `inter`
 * here; wire `inter.variable` onto <html> in the app's root layout.
 */
export const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
});
